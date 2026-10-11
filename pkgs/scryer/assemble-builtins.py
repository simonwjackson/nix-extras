#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3 cosign b3sum zstd openssl
"""Assemble locked, authenticated upstream assets without network access."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile


def assemble(args):
    source = Path(args.source)
    metadata = Path(args.metadata)
    output = Path(args.output)
    root = Path(args.trust_root)
    spec = importlib.util.spec_from_file_location(
        "upstream_materializer", source / "scripts/materialize-builtins.py"
    )
    upstream = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(upstream)
    provenance = json.loads((metadata / "provenance.json").read_text())
    receipt = json.loads((metadata / "sigstore-trusted-root.provenance.json").read_text())
    pins = json.loads((source / "crates/scryer-plugins/builtin-versions.json").read_text())
    if hashlib.sha256(root.read_bytes()).hexdigest() != receipt["sha256"]:
        raise ValueError("trust root does not match the TUF-verified receipt")
    upstream.validate_runtime_trust_root(json.loads(root.read_text()))
    for field, version in (
        ("scryer_version", upstream.current_scryer_version(source)),
        ("sdk_version", upstream.current_sdk_version(source)),
    ):
        if provenance["host"][field] != ".".join(map(str, version)):
            raise ValueError(f"refresh built-in provenance for the current {field}")
    if pins["schemaVersion"] != 2:
        raise ValueError("unsupported upstream built-in pin schema")
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary:
        temporary = Path(temporary)
        for plugin in ("newznab", "torznab"):
            record = provenance["plugins"][plugin]
            pin = pins["plugins"][plugin]
            if (record["version"], record["wasm_blake3"]) != (
                pin["version"], pin["wasm_blake3"]
            ):
                raise ValueError(f"{plugin} does not match the upstream source pin")
            blob = Path(getattr(args, f"{plugin}_wasm"))
            # File flake inputs have no extension. Decode explicitly.
            bundle_source = Path(getattr(args, f"{plugin}_bundle"))
            bundle = temporary / f"{plugin}.sigstore"
            upstream.zstd_decode(bundle_source, bundle)
            # Supply all verification material for the network-isolated builder.
            upstream.run(
                upstream.COSIGN, "--timeout", upstream.SIGSTORE_TRUST_ROOT_TIMEOUT,
                "verify-blob", "--bundle", str(bundle),
                "--trusted-root", str(root),
                "--certificate-identity-regexp", ".*",
                "--certificate-oidc-issuer", upstream.OIDC_ISSUER,
                "--certificate-github-workflow-repository", upstream.OFFICIAL_PLUGIN_REPOSITORY,
                "--certificate-github-workflow-name", upstream.OFFICIAL_PLUGIN_WORKFLOW_NAME,
                str(blob),
            )
            upstream.assert_blake3(plugin, blob, [f"blake3:{record['compressed_blake3']}"])
            wasm_path = temporary / f"{plugin}.wasm"
            wasm = upstream.zstd_decode(blob, wasm_path)
            upstream.assert_blake3(plugin, wasm_path, [f"blake3:{pin['wasm_blake3']}"])
            descriptor = upstream.embedded_descriptor(wasm)
            if (descriptor.get("id"), str(descriptor.get("version"))) != (
                plugin, pin["version"]
            ):
                raise ValueError(f"{plugin} descriptor does not match the source pin")
            descriptor_bytes = (json.dumps(descriptor, indent=2, sort_keys=True) + "\n").encode()
            if hashlib.sha256(descriptor_bytes).hexdigest() != record["descriptor_sha256"]:
                raise ValueError(f"{plugin} descriptor does not match verified provenance")
            if hashlib.sha256(bundle_source.read_bytes()).hexdigest() != record["signature_bundle_sha256"]:
                raise ValueError(f"{plugin} signature bundle does not match verified provenance")
            stem = f"{plugin}_indexer"
            shutil.copyfile(blob, output / f"{stem}.wasm.zst")
            (output / f"{stem}.descriptor.json").write_bytes(descriptor_bytes)
            bundle_output = output / "provenance" / f"{stem}.wasm.zst.sigstore"
            bundle_output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(bundle_source, bundle_output)
    shutil.copyfile(root, output / "sigstore-trusted-root.json")
    shutil.copytree(metadata, output, dirs_exist_ok=True)
    print("Verified both built-in signatures, source pins, descriptors, and trust receipt.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in (
        "source", "metadata", "output", "trust-root", "newznab-wasm",
        "newznab-bundle", "torznab-wasm", "torznab-bundle",
    ):
        parser.add_argument(f"--{argument}", required=True)
    assemble(parser.parse_args())


if __name__ == "__main__":
    main()

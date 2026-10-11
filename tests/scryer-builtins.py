#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3 cosign b3sum zstd openssl
"""Exercise real asset verification and reject three kinds of tampering."""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def invoke(arguments, expected_error=None):
    result = subprocess.run(
        [sys.executable, *arguments], text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if expected_error is None:
        assert result.returncode == 0, result.stdout
    else:
        assert result.returncode != 0, "tampered assets were accepted"
        assert expected_error in result.stdout, result.stdout
    return result.stdout


def replace_argument(arguments, name, value):
    arguments = list(arguments)
    arguments[arguments.index(name) + 1] = str(value)
    return arguments


def main():
    arguments = sys.argv[1:]
    with tempfile.TemporaryDirectory() as temporary:
        temporary = Path(temporary)
        arguments = replace_argument(arguments, "--output", temporary / "valid")
        assert "Verified both built-in signatures" in invoke(arguments)
        original = Path(arguments[arguments.index("--newznab-wasm") + 1])
        corrupted = bytearray(original.read_bytes())
        corrupted[0] ^= 1
        bad_wasm = temporary / "corrupted.wasm.zst"
        bad_wasm.write_bytes(corrupted)
        invoke(replace_argument(arguments, "--newznab-wasm", bad_wasm), "command failed (cosign")
        original = Path(arguments[arguments.index("--trust-root") + 1])
        bad_root = temporary / "wrong-root.json"
        bad_root.write_bytes(original.read_bytes() + b" ")
        invoke(replace_argument(arguments, "--trust-root", bad_root), "TUF-verified receipt")
        original = Path(arguments[arguments.index("--metadata") + 1])
        bad_metadata = temporary / "wrong-pin"
        shutil.copytree(original, bad_metadata, copy_function=shutil.copyfile)
        record = json.loads((bad_metadata / "provenance.json").read_text())
        record["plugins"]["newznab"]["wasm_blake3"] = "0" * 64
        (bad_metadata / "provenance.json").write_text(json.dumps(record))
        invoke(replace_argument(arguments, "--metadata", bad_metadata), "upstream source pin")
    print("Valid assets accepted; corrupted artifact, trust root, and source pin rejected.")


if __name__ == "__main__":
    main()

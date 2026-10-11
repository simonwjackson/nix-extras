#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3 nix
"""Test Nix's real importer with empty stores and no build fallback."""

import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def command(*args, **kwargs):
    result = subprocess.run(
        args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs
    )
    if result.returncode:
        raise RuntimeError(result.stderr.decode())
    return result


def main():
    fixture, registration, backend, flake, identity_path, entry_point = map(
        Path, sys.argv[1:]
    )
    identity = json.loads(identity_path.read_text())
    for setting, expected in [
        ("extra-substituters", identity["url"]),
        ("extra-trusted-public-keys", " ".join(identity["publicKeys"])),
    ]:
        actual = re.search(rf'{setting} = "([^"]+)";', flake.read_text())
        assert actual and actual.group(1) == expected, (
            f"flake setting differs from cache identity: {setting}"
        )
    spec = importlib.util.spec_from_file_location("cache_entry", entry_point)
    entry = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(entry)
    publisher = entry.load_publisher(backend)
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        source = work / "source"
        copied = source / str(fixture).lstrip("/")
        copied.parent.mkdir(parents=True)
        shutil.copytree(fixture, copied)
        os.environ["NIX_REMOTE"] = f"local?root={source}"
        os.environ["NIX_CONFIG"] = (
            "experimental-features = nix-command flakes\nsubstituters =\nbuilders =\nmax-jobs = 0\nfallback = false\nrequire-sigs = true\n"
        )
        with registration.open("rb") as data:
            command("nix-store", "--load-db", stdin=data)
        secret = work / "signer.secret"
        secret.write_bytes(
            command(
                "nix", "key", "generate-secret", "--key-name", "fixture-cache-1"
            ).stdout
        )
        secret.chmod(0o600)
        with secret.open("rb") as data:
            public = (
                command("nix", "key", "convert-secret-to-public", stdin=data)
                .stdout.decode()
                .strip()
            )
        cache = work / "cache"
        command(
            "nix",
            "copy",
            "--to",
            cache.as_uri() + f"?compression=zstd&secret-key={secret}",
            str(fixture),
        )
        prepared = work / "prepared"
        publisher.prepare(
            cache,
            prepared,
            "https://github.com/example/cache/releases/download/batch-test/",
            [],
        )
        note = next(cache.glob("*.narinfo"))
        _, original = publisher.metadata(note)
        _, rewritten = publisher.metadata(prepared / "metadata" / note.name)
        assert publisher.signed_identity(original) == publisher.signed_identity(
            rewritten
        )
        assert original["Sig"] == rewritten["Sig"]
        assert rewritten["URL"].startswith(
            "https://github.com/example/cache/releases/download/batch-test/"
        )
        command(
            "nix",
            "store",
            "verify",
            "--store",
            (prepared / "metadata").as_uri(),
            "--no-contents",
            "--sigs-needed",
            "1",
            "--option",
            "trusted-public-keys",
            public,
            str(fixture),
        )
        good = work / "good"
        base = [
            "nix",
            "copy",
            "--from",
            cache.as_uri(),
            "--option",
            "trusted-public-keys",
            public,
        ]
        command(*base, "--to", f"local?root={good}", str(fixture))
        assert (
            good / str(fixture).lstrip("/") / "value"
        ).read_text() == "signed cache fixture\n"
        denied = subprocess.run(
            [
                "nix",
                "copy",
                "--from",
                cache.as_uri(),
                "--to",
                f"local?root={work / 'denied'}",
                "--option",
                "trusted-public-keys",
                "",
                str(fixture),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert denied.returncode != 0, "untrusted signature was accepted"
        assert not (work / "denied" / str(fixture).lstrip("/")).exists()
        nar = next((cache / "nar").iterdir())
        nar.chmod(0o600)
        data = bytearray(nar.read_bytes())
        data[len(data) // 2] ^= 1
        nar.write_bytes(data)
        corrupted = subprocess.run(
            [*base, "--to", f"local?root={work / 'corrupted'}", str(fixture)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        assert corrupted.returncode != 0, "corrupted NAR was accepted"
        try:
            publisher.prepare(
                cache,
                work / "bad-prepared",
                "https://github.com/example/cache/releases/download/batch-test/",
                [],
            )
        except ValueError:
            pass
        else:
            raise AssertionError("publisher accepted a corrupted NAR")
        assert not (work / "bad-prepared").exists(), (
            "failed preparation exposed partial metadata"
        )
        print(
            "Cache identity and signed URL rewrite passed. Empty-store import passed; untrusted key and corrupted NAR rejected with builds disabled."
        )


if __name__ == "__main__":
    main()

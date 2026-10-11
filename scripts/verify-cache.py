#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3 nix
"""Restore public package closures into an empty store without any builders."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def verify(identity, paths):
    with tempfile.TemporaryDirectory(prefix="nix-extras-substitution-") as temporary:
        root = Path(temporary)
        store = f"local?root={root / 'store'}"
        environment = dict(os.environ, XDG_CACHE_HOME=str(root / "client-cache"))
        keys = " ".join(identity["publicKeys"] + identity["upstreamPublicKeys"])
        options = [
            "--store",
            store,
            "--option",
            "substituters",
            " ".join([identity["url"], *identity["upstreams"]]),
            "--option",
            "trusted-public-keys",
            keys,
            "--option",
            "require-sigs",
            "true",
            "--option",
            "builders",
            "",
            "--option",
            "fallback",
            "false",
            "--max-jobs",
            "0",
        ]
        subprocess.run(
            ["nix-store", *options, "--realise", *paths], env=environment, check=True
        )
        subprocess.run(
            [
                "nix",
                "store",
                "verify",
                "--store",
                store,
                "--no-contents",
                "--sigs-needed",
                "1",
                "--option",
                "substituters",
                "",
                "--option",
                "trusted-public-keys",
                keys,
                *paths,
            ],
            env=environment,
            check=True,
        )
        for path in paths:
            copied = root / "store" / path.lstrip("/")
            if not copied.is_dir():
                raise ValueError(
                    f"package was not restored into the isolated store: {path}"
                )
        print(
            f"Verified remote substitution of {len(paths)} package roots into an empty store with builds disabled and trusted signatures required."
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("identity", type=Path)
    parser.add_argument("paths", nargs="+")
    args = parser.parse_args()
    verify(json.loads(args.identity.read_text()), args.paths)


if __name__ == "__main__":
    main()

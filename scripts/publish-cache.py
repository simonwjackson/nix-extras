#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3 nix gh git
"""Publish only this checkout's tested packages as a signed release cache."""

import argparse
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from urllib.error import HTTPError
from urllib.parse import urlsplit, quote
from urllib.request import Request, urlopen


def run(*arguments, **kwargs):
    return subprocess.check_output(arguments, text=True, **kwargs).strip()


def load_publisher(path):
    loader = importlib.machinery.SourceFileLoader("release_cache", str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def fetch_metadata(url):
    try:
        with urlopen(url, timeout=60) as response:
            if urlsplit(response.geturl()).scheme != "https":
                raise ValueError("cache metadata redirected away from HTTPS")
            data = response.read(65537)
            if len(data) > 65536:
                raise ValueError("cache metadata exceeds 64 KiB")
            return data
    except HTTPError as error:
        if error.code == 404:
            return None
        raise


def omit_published(publisher, prepared, identity, work):
    """Skip only identical outputs with a signature this cache still trusts."""
    remote = work / "remote-metadata"
    verified = work / "verified-metadata"
    remote.mkdir()
    verified.mkdir()
    info = fetch_metadata(identity["url"] + "nix-cache-info")
    if info is None:
        return
    (remote / "nix-cache-info").write_bytes(info)
    (verified / "nix-cache-info").write_bytes(info)
    retained = []
    for note in sorted((prepared / "metadata").glob("*.narinfo")):
        data = fetch_metadata(identity["url"] + note.name)
        if data is None:
            continue
        downloaded = remote / note.name
        downloaded.write_bytes(data)
        _, local = publisher.metadata(note)
        text, previous = publisher.metadata(downloaded)
        if publisher.signed_identity(previous) != publisher.signed_identity(local):
            raise ValueError(
                f"published bytes differ for {note.name}; refusing replacement"
            )
        if not previous["URL"].startswith(identity["downloadBase"]):
            raise ValueError("published NAR URL is outside this repository")
        # CA paths must also pass the explicit signature check.
        (verified / note.name).write_text(
            "\n".join(line for line in text.splitlines() if not line.startswith("CA: "))
            + "\n"
        )
        with urlopen(Request(previous["URL"], method="HEAD"), timeout=60) as response:
            if urlsplit(response.geturl()).scheme != "https" or response.status != 200:
                raise ValueError("published NAR is not available over HTTPS")
            length = response.headers.get("Content-Length")
            if length is not None and int(length) != int(previous["FileSize"]):
                raise ValueError("published NAR size differs from its metadata")
        retained.append((note, local))
    if retained:
        run(
            "nix",
            "path-info",
            "--store",
            remote.as_uri(),
            *[fields["StorePath"] for _, fields in retained],
        )
        run(
            "nix",
            "store",
            "verify",
            "--store",
            verified.as_uri(),
            "--no-contents",
            "--sigs-needed",
            "1",
            "--option",
            "substituters",
            "",
            "--option",
            "trusted-public-keys",
            " ".join(identity["publicKeys"]),
            *[fields["StorePath"] for _, fields in retained],
        )
        for note, _ in retained:
            note.unlink()
        # Remove only payloads no remaining narinfo needs.
        needed = {
            publisher.metadata(note)[1]["URL"].rsplit("/", 1)[1]
            for note in (prepared / "metadata").glob("*.narinfo")
        }
        for nar in (prepared / "nars").iterdir():
            if nar.name not in needed:
                nar.unlink()
    print(f"Already published with trusted signatures: {len(retained)} paths.")


def publish_batch(publisher, prepared, repo, tag, cache_tag, revision):
    # A newly created draft can be absent from GitHub's release list briefly.
    # Retry only that visibility error, never a digest or signature failure.
    for attempt in range(4):
        try:
            return publisher.publish(prepared, repo, tag, cache_tag, revision)
        except ValueError as error:
            if (
                str(error) != "expected exactly one release with this tag"
                or attempt == 3
            ):
                raise
            found = publisher.release_records(repo, tag)
            if found and type(found[0].get("id")) is not int:
                raise
            print("New release is not yet visible. Retrying the same checked batch.")
            time.sleep(2 ** (attempt + 1))


def publish(args):
    revision = run("git", "rev-parse", "HEAD")
    if run("git", "status", "--porcelain", "--untracked-files=all"):
        raise ValueError("publish from a clean, committed checkout")
    identity = json.loads(run("nix", "eval", "--json", ".#cache"))
    key = Path(args.key_file).expanduser().resolve()
    if (
        not key.is_file()
        or key.stat().st_mode & 0o077
        or str(key).startswith("/nix/store/")
    ):
        raise ValueError("signing key must be private and outside the store")
    with key.open("rb") as source:
        public = run("nix", "key", "convert-secret-to-public", stdin=source)
    if public not in identity["publicKeys"]:
        raise ValueError("signing key is not trusted by this checkout")
    publisher = load_publisher(args.publisher)
    names = json.loads(
        run(
            "nix",
            "eval",
            "--json",
            ".#packages.x86_64-linux",
            "--apply",
            "builtins.attrNames",
        )
    )
    paths = run(
        "nix",
        "build",
        "--no-link",
        "--print-out-paths",
        "--max-jobs",
        "1",
        "--cores",
        "2",
        *[f".#packages.x86_64-linux.{name}^*" for name in names],
    ).splitlines()
    tag = f"batch-{revision}"
    with tempfile.TemporaryDirectory(
        prefix="nix-extras-cache-", dir=args.work_directory
    ) as temporary:
        work = Path(temporary)
        cache, prepared = work / "signed", work / "prepared"
        destination = (
            cache.as_uri() + "?compression=zstd&secret-key=" + quote(str(key), safe="")
        )
        subprocess.run(["nix", "copy", "--to", destination, *paths], check=True)
        publisher.prepare(
            cache, prepared, identity["downloadBase"] + tag + "/", identity["upstreams"]
        )
        omit_published(publisher, prepared, identity, work)
        if not list((prepared / "metadata").glob("*.narinfo")):
            print("Every package closure is already served by trusted caches.")
            verify_file = work / "identity.json"
            verify_file.write_text(json.dumps(identity))
            subprocess.run(
                ["python3", str(args.verify_script), str(verify_file), *paths],
                check=True,
            )
            return
        repo = identity["repo"]
        if not publisher.release_records(repo, identity["metadataTag"]):
            run(
                "gh",
                "release",
                "create",
                identity["metadataTag"],
                "--repo",
                repo,
                "--target",
                revision,
                "--latest=false",
                "--title",
                "Signed Nix cache metadata",
                "--notes",
                "Mutable signed narinfo index. Payload releases are retained without automatic pruning.",
            )
        if not publisher.release_records(repo, tag):
            # The tag binds this batch to the exact source commit that was checked.
            try:
                publisher.api(f"repos/{repo}/git/ref/tags/{tag}")
            except subprocess.CalledProcessError:
                # Recheck with captured status. Only an explicit 404 permits creation.
                status = subprocess.run(
                    ["gh", "api", f"repos/{repo}/git/ref/tags/{tag}"],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                if status.returncode == 0:
                    raise ValueError("tag appeared concurrently; retry publication")
                if "HTTP 404" not in status.stderr:
                    raise RuntimeError(status.stderr.strip())
                run(
                    "gh",
                    "api",
                    "--method",
                    "POST",
                    f"repos/{repo}/git/refs",
                    "--raw-field",
                    f"ref=refs/tags/{tag}",
                    "--raw-field",
                    f"sha={revision}",
                )
        publish_batch(publisher, prepared, repo, tag, identity["metadataTag"], revision)
        print(
            f"Published {len(paths)} package roots from {revision} to {identity['url']}"
        )
        verify_file = work / "identity.json"
        verify_file.write_text(json.dumps(identity))
        subprocess.run(
            ["python3", str(args.verify_script), str(verify_file), *paths], check=True
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publisher", type=Path, required=True)
    parser.add_argument("--verify-script", type=Path, required=True)
    parser.add_argument(
        "--key-file",
        default=os.environ.get(
            "NIX_EXTRAS_CACHE_SECRET_KEY_FILE", "~/.config/nix-extras/cache-ci-1.secret"
        ),
    )
    parser.add_argument(
        "--work-directory", default=os.environ.get("NIX_EXTRAS_CACHE_WORK_DIRECTORY")
    )
    publish(parser.parse_args())


if __name__ == "__main__":
    main()

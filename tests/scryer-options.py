#!/usr/bin/env nix-shell
#!nix-shell -i python3 -p python3
"""Exercise real bootstrap credentials and offline WASM upload inside the VM."""

import base64
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
from urllib.request import Request, urlopen

PASSWORD = Path("/run/scryer-admin-password")


def graphql(query, variables=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    request = Request(
        "http://127.0.0.1:8080/graphql",
        data=json.dumps({"query": query, "variables": variables or {}}).encode(),
        headers=headers,
    )
    with urlopen(request, timeout=120) as response:
        result = json.load(response)
    # Do not print response errors: they might include request values.
    assert not result.get("errors"), "GraphQL returned errors"
    return result["data"]


def prepare():
    # Generate the fixture at runtime: even the test derivation has no password.
    with os.fdopen(os.open(PASSWORD, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
        output.write(secrets.token_urlsafe(32) + "\n")
    Path("/run/scryer-options.env").write_text(
        "SCRYER_ADMIN_USERNAME=wrong-user\nSCRYER_ADMIN_PASSWORD_FILE=/run/missing-password\n"
    )


def verify(plugin):
    password = PASSWORD.read_text().strip()
    assert PASSWORD.stat().st_mode & 0o777 == 0o600
    assert PASSWORD.stat().st_uid == 0
    result = graphql(
        "mutation($input: LoginInput!) { login(input: $input) { token } }",
        {"input": {"username": "operator", "password": password}},
    )
    token = result["login"]["token"]
    assert token
    result = graphql(
        "mutation($input: ManualPluginUploadInput!) { installUploadedPlugin(input: $input) { pluginId version } }",
        {"input": {
            "fileName": "plugin-v3.wasm.zst",
            "wasmBase64": base64.b64encode(Path(plugin).read_bytes()).decode(),
            "acknowledgeRisk": True,
        }},
        token,
    )
    assert result["installUploadedPlugin"]["pluginId"] == "transmission"
    assert result["installUploadedPlugin"]["version"] == "2.0.2"
    result = graphql("{ plugins { id isInstalled installedVersion } }", token=token)
    assert any(item["id"] == "transmission" and item["isInstalled"] and item["installedVersion"] == "2.0.2"
               for item in result["plugins"])

    for command in (["systemctl", "cat", "scryer"], ["journalctl", "-u", "scryer", "--no-pager"]):
        text = subprocess.check_output(command)
        assert password.encode() not in text, "password leaked into unit or journal"
    scan = subprocess.run(
        ["grep", "-rFl", "--binary-files=text", "-f", str(PASSWORD), "/nix/store"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    assert scan.returncode == 1, "password found in store, or store scan failed"
    print("Credential login, offline plugin upload/listing, and leak checks passed.")


if __name__ == "__main__":
    if sys.argv[1] == "prepare":
        prepare()
    else:
        verify(sys.argv[2])

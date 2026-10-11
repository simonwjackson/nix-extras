#!/usr/bin/env nix-shell
#!nix-shell -i bash -p nix git
set -euo pipefail

repo=$(git rev-parse --show-toplevel)
cd "$repo"
source=$(nix eval --raw .#scryer.src.outPath)
revision=$(nix eval --raw .#scryer.src.rev)
nixpkgs=$(nix eval --raw --impure --expr "(builtins.getFlake \"$repo\").inputs.nixpkgs.outPath")
output=$(mktemp -d "${TMPDIR:-/tmp}/scryer-verified-builtins.XXXXXX")
mkdir -p "$output/home"
unset GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_WORKFLOW GITHUB_JOB

nix shell "$nixpkgs#python3" "$nixpkgs#cosign" "$nixpkgs#b3sum" \
  "$nixpkgs#zstd" "$nixpkgs#openssl" --command \
  env HOME="$output/home" GITHUB_SHA="$revision" \
  python3 "$source/scripts/materialize-builtins.py" \
    --repo-root "$source" --output "$output/builtins"

printf '\nVerified upstream assets and provenance: %s/builtins\n' "$output"
printf 'The repository is unchanged. Follow docs/maintenance.md to refresh metadata and input URLs.\n'

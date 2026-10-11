# Signed binary cache

The cache uses GitHub Release assets in `simonwjackson/nix-extras`.

| Item | Location or rule |
| --- | --- |
| Cache metadata | The public, mutable `cache` release contains `nix-cache-info` and signed `.narinfo` files. |
| Archives | Public `batch-<source-commit>` releases contain compressed NAR files. |
| Signing identity | `cache/identity.nix` exports the URL and public keys. The contract test checks the literal flake settings against that identity. |
| Scope | Runtime closures of all exported `packages.x86_64-linux`. Compiler, test, and machine-wide closures are not selected. |
| Shared dependencies | Paths with matching NAR identities and trusted signatures at `cache.nixos.org` are not uploaded again. |
| Retention | Published batches and metadata are not pruned automatically. GitHub availability is not permanent storage. |

## Trust the cache

For direct use, accept the flake's public settings:

```sh
nix build --accept-flake-config github:simonwjackson/nix-extras#nzbfast
nix build --accept-flake-config github:simonwjackson/nix-extras#scryer
```

`nixConfig` from an input flake does not configure the parent flake or its daemon. On NixOS, set these options where your `inputs` argument is available:

```nix
nix.settings = {
  extra-substituters = [ inputs.nix-extras.cache.url ];
  extra-trusted-public-keys = inputs.nix-extras.cache.publicKeys;
};
```

For other systems, an administrator can add these lines to `nix.conf`:

```text
extra-substituters = https://github.com/simonwjackson/nix-extras/releases/download/cache/
extra-trusted-public-keys = nix-extras-ci-1:+Vcq7i6dPWOsOZjQwOduCEZOZZJznS/XfOcNUhFmg3Q=
```

Restart the daemon after changing its configuration. Keep `require-sigs = true`. Never fix a failed substitution with `--no-check-sigs`.

The cache covers the default locked packages. Overlay, compiler, source, and build-option overrides can produce different store paths. Unpublished revisions can require a build. This cache does not add another supported platform.

## Publication and verification

The workflow uses separate jobs for untrusted pull requests and trusted `main` commits. Both use the same validation action. Only the `main` job has `contents: write`. The signing secret becomes an environment value only in the key-staging step after every check passes. Pull request jobs have no publishing step and cannot read the secret.

Publication is serialized with `cancel-in-progress: false`. The publisher requires a clean checkout, builds the selected packages, and verifies the signing key against the public identity. It exports closures through Nix. Nix owns signatures and metadata.

The publisher verifies archives before upload. It publishes and verifies payload assets before exposing new metadata. It never replaces a differing asset. It retries a new release's visibility error up to three times, with delays of 2, 4, and 8 seconds. Digest and signature failures are not retried. An interrupted upload can leave a partial draft or public batch; retry the same checked commit. Inspect a digest collision instead of deleting or overwriting assets.

After publication, the publisher imports both package closures into a new local store. It disables all builders and build fallback, requires trusted signatures, and uses only this cache and `cache.nixos.org`. A separate native verification checks the imported package signatures. The same test runs when a retry finds every package already cached.

The offline contract test exercises Nix's real file-cache exporter and importer. It checks signed URL rewriting, successful empty-store import, rejection of an untrusted key, and rejection of a corrupted archive. It also requires failed preparation to expose no partial metadata.

GitHub limits a release to 1,000 assets and each asset to less than 2 GiB. The publisher fails rather than silently prune or overwrite at those limits. Before the metadata release fills, maintainers must migrate the index or storage. This design does not solve that future capacity limit or GitHub outages.

## Signing-key handling

The Actions secret is `NIX_EXTRAS_CACHE_SECRET_KEY`. The workflow writes it to a mode-`0600` file under `RUNNER_TEMP`, never into the checkout or the Nix store. An `always()` step removes that file.

The initial cache bootstrap uses the same CI key from a private local file. That host is therefore an additional signing trust boundary. Keep the backup private or move it to offline storage. Do not print the key, commit it, include it in an artifact, or pass its contents on a command line.

For manual maintenance, use the same checked, committed source and a trusted key file:

```sh
NIX_EXTRAS_CACHE_SECRET_KEY_FILE=/private/path/cache-key.secret nix run .#cache-publish
```

A maintainer needs repository release-write permission. The key's derived public value must occur in `cache/identity.nix`. Local publication is a signing action, not a test substitute. Run all checks before signing.

Changing public keys requires a planned migration. The publisher does not merge or replace existing signatures under the same asset name. Existing metadata signed only by a removed key will fail the explicit trust check. Do not remove an old key until consumers and published metadata have a verified replacement. A compromised key requires revocation and repair; retaining it for compatibility is not safe.

## Korri publisher and source

This repository follows [Korri's cache methodology](https://github.com/korri-os/korri/tree/e6902f0f3c7c2081db033b31c4cd6557b254537a/nix/cache). The optional publisher imports its unmodified `github-cache.py` through a hash-locked, non-flake file input. It adds this repository's package selection, cache identity, existing-publication check, and remote substitution verification.

The pinned Korri tree has no repository-wide license. Its source is not copied into this repository or relicensed under this repository's MIT license. The application packages and service modules do not depend on the publisher. Building or using the applications does not require a Korri checkout or system.

Payload tags identify the checked recipe commit. That commit retains the package expressions, upstream source pins, application licenses, and Scryer's authenticated asset pins. The cache serves those builds, not upstream release executables.

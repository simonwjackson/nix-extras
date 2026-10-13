# Maintenance

## Package boundaries

Each application has one package expression and one optional NixOS module. The flake selects sources, exposes packages, and supplies module defaults. Package expressions accept `src` through `callPackage`, so they remain usable outside this flake.

Sources are non-flake inputs with release URLs and committed lock entries. Cargo and npm dependency hashes are separate from source hashes. No application executable is fetched from release assets, except ReSkate's (see below).

Scryer's application source omits generated built-in assets. Five non-flake file inputs lock its two compressed WASM plugins, two compressed Sigstore bundles, and a Sigstore trust snapshot. The package also takes these paths through `builtinInputs`, so `callPackage` does not require a flake. The asset builder checks signatures with upstream signer restrictions, BLAKE3 pins from the application source, and descriptor hashes. Verification runs in the network-isolated Nix sandbox.

Modules configure service execution and filesystem access. They do not declare provider credentials, indexers, application migrations, or a connection between the applications. This keeps secrets and application-owned settings outside the store, but initial application setup remains manual.

The module exports use the flake's own package set for their default packages. The overlay instead builds with the consumer's package set. This distinction keeps module defaults on the locked compiler without forcing consumers to install an overlay.

## Update a release

1. Inspect the new upstream tag, Cargo lockfile, runtime flags, environment variables, license, and release notes. For Scryer, inspect its frontend lockfile, `builtin-versions.json`, and asset materializer too.
2. Change the release URL in `flake.nix` and `version` in the package expression. Update the corresponding version assertion in its VM test.
3. Update only that source input, then stage the changed lockfile.

   ```sh
   nix flake update nzbfast-src
   git add flake.nix flake.lock pkgs/nzbfast/package.nix tests/nzbfast.nix
   ```

   Use `scryer-src` for Scryer. Updating a release-pinned input without changing its URL does not select a newer release.

4. Replace the changed `cargoHash` with `lib.fakeHash`. For Scryer, also replace `npmDepsHash` when its frontend lockfile changes.
5. Build the dependency derivations and copy their reported hashes into the expression.

   ```sh
   nix build .#nzbfast.cargoDeps --no-link -L --max-jobs 1 --cores 2
   nix build .#scryer.cargoDeps .#scryer.webui.npmDeps --no-link --keep-going -L --max-jobs 1 --cores 2
   ```

   With the locked Nixpkgs revision, the Cargo mismatch can name `vendor-staging`. Its reported hash is the value expected by `cargoHash`. Do not substitute a hash of the processed vendor directory.

6. For Scryer, refresh its verified built-in metadata and file inputs as described below. The host version and SDK must match the captured provenance.
7. Run formatting, evaluation, builds, and the VM tests.

   ```sh
   nix fmt
   nix flake check --no-build -L
   nix flake check -L --max-jobs 1 --cores 2
   ```

8. Update the README versions and coverage limitations. Merge to `main` only after the checks pass.

Stage new Nix files before evaluation. Git flakes omit untracked files.

## Update ReSkate

ReSkate is the one prebuilt package. Its client is Windows code that upstream builds with MSVC only, so the `reskate-client` input is the release zip, not source. Upstream releases often; 2.0.5, 2.0.6, and 2.0.7 came out within two days.

1. Read the release notes. Check that the zip still holds `ReSkateLauncher.exe`, `ReSkate.dll`, `launcher.json`, `LICENSE.txt`, and `licenses/`.
2. Change the version in the `reskate-client` URL in `flake.nix` and `version` in `pkgs/reskate/package.nix`.
3. Update the input and compare the file with the release asset's published SHA-256 digest.

   ```sh
   nix flake update reskate-client
   sha256sum "$(nix eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.reskate-client.outPath')"
   ```

4. Run `nix build .#checks.x86_64-linux.reskate .#checks.x86_64-linux.reskate-install --no-link -L`. The package check fails when the zip's `launcher.json` names another version.

The installed launcher updates itself, so a late package update affects only new installs.

## Refresh Scryer built-ins

Run `bash scripts/refresh-scryer-builtins.sh` from the checkout. It uses tools from the locked Nixpkgs input and a fresh temporary HOME. The upstream materializer verifies the signed catalog, signed plugin blobs, source pins, and a TUF-authenticated trust root. It writes a temporary snapshot and leaves the repository unchanged.

Copy these snapshot files into `pkgs/scryer/builtin-metadata`, keeping their relative paths:

- `provenance.json` records the selected host, SDK, plugin versions, URLs, and hashes.
- `sigstore-trusted-root.provenance.json` records the TUF retrieval, source commit, tool version, and root hash.
- `newznab_indexer.description.txt` and `torznab_indexer.description.txt` retain upstream descriptions.
- `provenance/catalog-v3.redirect.bundle.json` and `provenance/catalog-v3.bundle.sigstore` retain the verified catalog receipts.

Do not copy WASM binaries or the trust root into the repository. Set the four plugin file-input URLs in `flake.nix` from `provenance.json`. Set the root URL to `https://tuf-repo-cdn.sigstore.dev/targets/<sha256>.trusted_root.json`, using the receipt's SHA256. Update only these five file inputs with `nix flake update`, then stage the metadata and lockfile.

Run `nix build .#checks.x86_64-linux.scryer-builtins --no-link -L` before the full build. It accepts valid assets and rejects a changed artifact, changed trust root, and mismatched source pin. Do not bypass signatures, alter source pins to fit an unrelated artifact, or generate dummy trust files.

The build verifies the saved root hash and root structure. TUF authentication occurs during the refresh, not through a network request during compilation. Root rotation and revocation changes need an explicit snapshot update. The retrieval timestamp stays fixed in Git for reproducible builds. A refresh changes embedded inputs and can require a full Scryer rebuild even when plugin versions remain unchanged.

## Scryer 0.21.15 update

The release is pinned to `bb56c3f7c546c4f3c6e9d12c587be66b3a0eaa7f`. Cargo and npm dependency hashes both changed. The upstream materializer refreshed host/SDK provenance to 0.21.15 / 3.15.0 and retained Newznab/Torznab 2.2.3 and the same TUF trust root. The offline assembler and signature restrictions remain unchanged; the existing build method still works.

Transmission 2.0.2 and Jellyfin 1.1.1 use non-flake file inputs, following this repository's source convention instead of `fetchurl`. The lockfile contains NAR hashes; `pkgs/scryer/plugin.nix` independently checks the raw release SHA-256 and byte size before installing each asset. Updating a plugin requires changing the input URL, version, raw hash, and size together. The cache publisher discovers all package outputs, so it publishes both plugin packages without a separate package list.

## Test scope

| Check | Scope |
| --- | --- |
| `nzbfast` | Source build, `nzbkit-base` yEnc unit tests, installed executable version/help |
| `scryer` | Rust and frontend source builds, verified built-in assets, `scryer-release-parser` library unit tests |
| `scryer-builtins` | Offline verification of real upstream plugin signatures, root receipt and source pins; three tampering failures |
| `reskate` | Release zip unpacks, `launcher.json` matches the package version, installer starts |
| `reskate-install` | Installer against a Steam folder layout in a temp directory: game missing, older game build, second run, self-updated launcher kept, existing launch option kept, Steam running, `--force` |
| `module-options` | Disabled modules, package overrides, loopback defaults, firewall options, user/group assertions, IPv6 command construction, environment files, writable/read-only paths, credential wiring, group/umask/readiness defaults |
| `nzbfast-service` | Two real NixOS VMs, authenticated API, held synthetic NZB persistence, key permissions, custom user/directories, listener settings, firewall behavior, retained state when disabled |
| `scryer-service` | Two real NixOS VMs, readiness and embedded UI, database/key persistence, custom user/directories, runtime environment, self-upgrade policy, firewall behavior, retained state when disabled |
| `scryer-options` | Runtime root-only credential fixture, GraphQL login, store/unit/journal leak scan, umask, read-only mount, supplementary group writes, dependent readiness ordering, offline Transmission upload/listing |
| `scryer-plugin-transmission` / `scryer-plugin-jellyfin` | Release file input, raw SHA-256 and byte-size check, stable installed path |

Run a service test directly with `nix build .#checks.x86_64-linux.nzbfast-service -L --max-jobs 1 --cores 2`. Substitute `scryer-service` for Scryer.

The package unit tests are deliberate subsets. They are not the complete upstream suites. No broad test-skip list from an older release is carried forward. Scryer's Wasmtime plugins need executable memory, so its service must not use `MemoryDenyWriteExecute`.

The checks do not prove download throughput, provider behavior, long-running reliability, media import compatibility, or the complete NZBFAST/Scryer workflow. Add controlled integration fixtures before making those claims. Do not test against live accounts or real provider credentials in CI.

## Platform and CI policy

Only `x86_64-linux` is exported. To add `aarch64-linux`, first build both packages and run their service tests on that system. Changing `meta.platforms` or adding an output without running the builds does not establish support.

CI uses pinned action commits and a read-only GitHub token. It runs sequential builds with two build cores. It removes unused Android, .NET, and GHC SDK directories only on the disposable hosted runner, then requires KVM for the VM tests. It does not install these services on a live host. Passing main builds publish the signed package cache; pull requests and branch workflow runs cannot publish it.

The packages select thin LTO and 16 codegen units to limit compiler memory. These settings differ from upstream release profiles and can change executable size or performance. No comparative memory or performance benchmark is available.

When updating Nixpkgs, verify Cargo vendor hashing, Rust compatibility, npm hooks, and the VM test driver again. Review pinned CI action updates as code changes.

## State and rollback

Keep state and downloads separate. Back up Scryer's database together with its encryption key. Keep NZBFAST's API key, settings, configuration, and spool together. Provider credentials can exist in these files.

The modules do not erase data on disable or move files on a path change. A new user can lack permission to read old private keys. Plan ownership changes explicitly. Returning to an older system generation does not reverse database migrations; restore a matching backup if an application downgrade requires it.

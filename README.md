# nix-extras

Community Nix packages, overlays, and NixOS modules.

[![Check](https://github.com/simonwjackson/nix-extras/actions/workflows/check.yml/badge.svg)](https://github.com/simonwjackson/nix-extras/actions/workflows/check.yml)

| Package | Release | Exported system | Application license |
| --- | --- | --- | --- |
| [NZBFAST](https://github.com/nzbfast/nzbfast) | 1.7.1 | `x86_64-linux` | GPL-3.0-or-later |
| [Scryer](https://github.com/scryer-media/scryer) | 0.21.15 | `x86_64-linux` | GPL-3.0-only |
| [ReSkate](https://github.com/Dingo-Shenanigans/ReSkate) | 2.0.7 | `x86_64-linux` | GPL-3.0-only |

NZBFAST and Scryer compile the Rust executable from pinned upstream source. NZBFAST embeds its dashboard and native repair/extraction code. Scryer's web UI builds with npm and embeds into its executable.

Scryer's generated built-in assets are not committed in its application source. This flake locks upstream Newznab and Torznab WASM assets, their signature bundles, and a TUF-verified Sigstore trust snapshot. The build verifies plugin signatures, source BLAKE3 pins, and embedded descriptors without network access. This repository does not rebuild the WASM plugins.

ReSkate is the exception: it is a prebuilt release. See [ReSkate](#reskate).

No Docker, application fork, or `mountainous` dependency is required. `aarch64-linux` is not exported or claimed as tested.

## Try the packages

```sh
nix run --accept-flake-config github:simonwjackson/nix-extras#nzbfast -- --version
nix run --accept-flake-config github:simonwjackson/nix-extras#scryer -- --version

nix build --accept-flake-config github:simonwjackson/nix-extras#nzbfast
nix build --accept-flake-config github:simonwjackson/nix-extras#scryer
```

The flake offers a signed binary cache in this repository's GitHub Release assets. `--accept-flake-config` opts into its URL and public signing key. Nix still checks archive hashes and trusted signatures. If your daemon does not trust these settings, an administrator must configure it.

The cache covers published builds of the default locked packages on `x86_64-linux`. Compiler or overlay overrides can produce different store paths that require a source build. GitHub availability is not guaranteed. See [binary cache notes](docs/binary-cache.md) for permanent configuration and maintenance.

## Use the NixOS modules

Add the input and modules to your existing flake. Keep your host configuration in `configuration.nix`.

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.nix-extras.url = "github:simonwjackson/nix-extras";

  outputs = inputs: {
    nixosConfigurations.your-host = inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        inputs.nix-extras.nixosModules.nzbfast
        inputs.nix-extras.nixosModules.scryer
        {
          services.nzbfast = {
            enable = true;
            group = "media";
            downloadDir = "/srv/downloads/usenet";
          };
          services.scryer = {
            enable = true;
            group = "media";
            writablePaths = [ "/srv/downloads/usenet" "/srv/media" ];
          };
          systemd.tmpfiles.rules = [ "d /srv/media 2770 scryer media -" ];
        }
      ];
    };
  };
}
```

The modules use this flake's locked packages by default. They do not require an overlay. A service's `package` option can select another build.

An input flake's cache settings do not apply automatically to your host flake. Add this to your NixOS configuration to trust the cache:

```nix
nix.settings = {
  extra-substituters = [ inputs.nix-extras.cache.url ];
  extra-trusted-public-keys = inputs.nix-extras.cache.publicKeys;
};
```

This example requires `inputs` in the configuration's scope, or pass it through `specialArgs`.

After your normal `nixos-rebuild switch`, NZBFAST listens at `http://127.0.0.1:6789` and Scryer at `http://127.0.0.1:8080`. From another machine, use SSH forwarding or an authenticated reverse proxy.

The services remain independent. Configure providers and indexers in their application settings. Add NZBFAST to Scryer as a SABnzbd-compatible download client, using `http://127.0.0.1:6789` and NZBFAST's API key. Enabling both modules does not configure that connection or prove end-to-end download compatibility.

## ReSkate

[ReSkate](https://github.com/Dingo-Shenanigans/ReSkate) adds offline play, your own lobbies and servers, and mods to skate. on Steam. Its client is two Windows files, `ReSkateLauncher.exe` and `ReSkate.dll`, that run inside skate. under Proton. Upstream builds them with MSVC only, so this package takes them from the release zip and does not compile them.

Steam owns the game folder, so Nix cannot put the files there. The package gives you `reskate-install`, which:

1. finds skate. (Steam app 3354750) in your Steam libraries,
2. copies the two files beside `Skate.exe`,
3. sets the skate. launch option that starts ReSkate's launcher in place of EA's anti-cheat launcher, which refuses to run under Proton.

Install skate. in Steam first. Then quit Steam, because Steam rewrites its config when it exits, and run:

```sh
nix run --accept-flake-config github:simonwjackson/nix-extras#reskate
```

Start Steam and press Play on skate. If Steam has updated the game past the build that ReSkate supports (`game.build_id` in `share/reskate/launcher.json`), the launcher asks you to sign in to Steam and downloads that build.

| Flag | Effect |
| --- | --- |
| `--skip-launch-options` | Copy the files only. |
| `--force` | Replace files that differ, and replace an existing launch option. |
| `--steam-dir DIR` | Use this Steam root. Repeatable. Default: `~/.local/share/Steam` and `~/.steam/steam`. |

The launch option is upstream's: `bash -c 'exec "${@/EAAntiCheat.GameServiceLauncher.exe/ReSkateLauncher.exe}"' -- %command%`. Exit codes: `0` done, `2` skate. is not installed, `3` the launch option was not written (Steam is running, or skate. already has a different launch option). The first write keeps each changed file as `localconfig.vdf.reskate-backup`.

The launcher updates itself and `ReSkate.dll` in the game folder. Players and servers must run the same ReSkate version, so leave that on. For that reason `reskate-install` does not replace a file that differs from its own copy unless you pass `--force`. The package version matters only for the first install.

The flake contains no game files. ReSkate's Linux dedicated server is not packaged.

## Options and state

| Option | NZBFAST default | Scryer default |
| --- | --- | --- |
| `enable` | `false` | `false` |
| `package` | Flake package | Flake package |
| `user` / `group` | `nzbfast` / `nzbfast` | `scryer` / `scryer` |
| `stateDir` | `/var/lib/nzbfast` | `/var/lib/scryer` |
| `listenAddress` | `127.0.0.1` | `127.0.0.1` |
| `port` | `6789` | `8080` |
| `openFirewall` | `false` | `false` |
| `environmentFile` | `null` | `null` |
| `writablePaths` | `[]` | `[]` |
| `supplementaryGroups` | Not applicable | `[]` |
| `umask` | Not applicable | `"0007"` |
| `readOnlyPaths` | Not applicable | `[]` |
| `adminPasswordFile` | Not applicable | `null` |
| `adminUsername` | Not applicable | `"admin"` |
| `environment` / `settings` (alias) | Not applicable | `{}` |
| `waitForReady` | Not applicable | `false` |
| `downloadDir` | `/var/lib/nzbfast/downloads` | Not applicable |

State directories have mode `0700`. NZBFAST creates its download directory with mode `2770` for group access. For sharing, place downloads outside the private state directory, as in the example. A private parent directory blocks other group members even when the download directory itself has group permission.

The default users are dedicated system accounts. A custom `user` must already exist. The module creates the named group if absent. `root` is refused for both user and group.

The systemd units can write their state directory, NZBFAST's download directory, declared `writablePaths`, and their private temporary directories. Create additional directories with suitable ownership before startup. Use paths outside `/home` and `/root`, which the units hide. These restrictions can block custom scripts or imports until you grant the required paths. External commands can be added with `systemd.services.<name>.path`.

NZBFAST's saved settings normally override command-line options. Before each start, the module atomically resets only `bind`, `port`, and `out_dir` in an existing `settings.json`. Other fields remain unchanged. Invalid JSON fails startup without replacing the original file. Change these three settings in Nix, not in the dashboard.

Scryer's `supplementaryGroups` grants the process extra groups; create those groups separately. `umask` accepts three or four octal digits. `readOnlyPaths` maps to systemd `ReadOnlyPaths`. The module rejects overlaps (including parent/child paths) with `writablePaths` or `stateDir`. Use canonical paths without symlink aliases for access policy.

`environment` adds non-secret string environment variables, such as `SCRYER_AUTH_ENABLED = "true"`. `settings` is an alias, not a second source of settings. `waitForReady = true` polls `/health/ready` for JSON `ready: true` for up to 180 seconds. Failed readiness fails startup. Units with `After=scryer.service` and `Requires=scryer.service` then wait for migrations. Wildcard listeners are polled through loopback; IPv6 is supported.

Scryer's bind address and self-upgrade policy also remain controlled by the module. In-application binary upgrades are disabled. NZBFAST 1.7.1 only notifies about updates. Update these packages through Nix.

Disabling either module does not delete its state, libraries, or downloads. Changing a user or directory does not migrate existing files. Back up state before changing ownership, moving directories, or upgrading. Nix rollback does not undo application database migrations.

## Secrets and access

Keep provider credentials, API keys, and mutable settings out of Nix expressions and the Nix store. Let the applications store them in their private state directories.

For upstream environment settings, pass a runtime file path as a **string**:

```nix
services.scryer.environmentFile = "/run/secrets/scryer.env";
```

Provision this file with your secret manager or a separate administrative step. Restrict its mode to `0600`; systemd reads it before dropping privileges. Do not use `environment.etc.<name>.text`, `builtins.readFile`, or a Nix path literal for real secrets.

NZBFAST generates a private API key on a fresh start. Read it from `${stateDir}/apikey` as an administrator and configure clients with that key.

Scryer retains its upstream authentication defaults. Loopback binding is not an authentication layer against other local users. Before exposing Scryer, configure authentication and replace any bootstrap admin credentials. Prefer systemd credentials:

```nix
services.scryer = {
  adminPasswordFile = "/run/secrets/scryer-admin-password";
  adminUsername = "admin";
  environment.SCRYER_AUTH_ENABLED = "true";
  waitForReady = true;
};
```

Provision the password file separately, owned by root with mode `0600`. The module passes `LoadCredential=admin-password:<path>` and `SCRYER_ADMIN_PASSWORD_FILE=%d/admin-password`. Systemd gives the service a private readable copy; the source stays root-only and is not imported into the store. `adminUsername` sets `SCRYER_ADMIN_USERNAME` only when `adminPasswordFile` is set. These credential settings take precedence over the optional environment file. They bootstrap a fresh admin, not reset an existing password. If you enable form login, Scryer refuses an unchanged `admin` password.

Never put passwords in `environment` or `settings`. Upstream also supports runtime `SCRYER_ADMIN_PASSWORD_FILE` or `SCRYER_ADMIN_PASSWORD` through `environmentFile`; without the credential option, any referenced file must be readable by the service user.

To allow direct remote access, set both `listenAddress = "0.0.0.0"` and `openFirewall = true`. Do not expose either application to the Internet without authentication and TLS.

## Outputs and reuse

The flake exports `packages.x86_64-linux.{nzbfast,reskate,scryer,scryer-plugin-transmission,scryer-plugin-jellyfin}`, `nixosModules.{nzbfast,scryer}`, `overlays.default`, a formatter, `checks.x86_64-linux`, the public `cache` identity, and the maintenance app `apps.x86_64-linux.cache-publish`.

For an overlay, add `inputs.nix-extras.overlays.default` to `nixpkgs.overlays`. This exposes `pkgs.nzbfast` and `pkgs.scryer`; it uses your package set and compiler.

The pinned plugin packages contain `share/scryer/plugins/<plugin>/plugin-v3.wasm.zst`: Transmission 2.0.2 and Jellyfin 1.1.1. Non-flake file inputs lock the release URLs and NAR hashes. Package builds also check the supplied raw SHA-256 and byte size. They do not auto-install plugins into mutable Scryer state. Upload them through Scryer's UI or `installUploadedPlugin`, with explicit risk acknowledgement. Manual uploads are unverified in Scryer's trust model, even though this flake checks their pinned hashes.

The expressions in `pkgs/*/package.nix` are ordinary `callPackage` functions. Supply the pinned source through their `src` argument. Scryer also takes `builtinInputs`, containing `newznabWasm`, `newznabBundle`, `torznabWasm`, `torznabBundle`, and `trustRoot` file paths. The exported Scryer package exposes its locked `builtinInputs` for reuse. These files must match the verified metadata in `pkgs/scryer/builtin-metadata`.

The expressions do not import a flake, fetch an application executable, or depend on the service modules. The module files can also be imported directly if you set their `package` options.

Older consumer package sets can have compilers that reject the pinned Cargo dependencies. Use the locked flake packages for the tested toolchain. The builds use thin LTO and 16 codegen units to reduce peak compiler memory; their optimization settings differ from the upstream release builds.

## Checks and maintenance

```sh
nix fmt -- --ci
nix flake check -L --max-jobs 1 --cores 2
```

Checks include selected upstream Rust unit tests, signed-asset verification with tampering tests, signed-cache import tests, and NixOS VM service tests. The VMs exercise HTTP readiness, embedded UI, generated key permissions, unprivileged execution, restart persistence, custom users/directories, firewall settings, and disabling without deleting state. A credential VM also checks admin GraphQL login, password absence from the store/unit/journal, umask, supplementary groups, read-only mounts, readiness ordering, and offline Transmission upload/listing. They use temporary state and no real provider credentials. The full upstream test suites, real Usenet downloads, media imports, and an NZBFAST-to-Scryer workflow are not tested here.

The VM tests require Linux with working KVM. CI fails rather than skips when KVM is unavailable. Cold builds can take substantially longer than evaluation; keep builds sequential on shared machines.

See [maintenance notes](docs/maintenance.md) for updating sources and hashes. Passing `main` builds publish selected package closures to the signed cache. Pull request jobs cannot use the signing secret or publish releases.

## License and attribution

The Nix code and documentation use the MIT license in [LICENSE](LICENSE). Application licenses remain unchanged.

The Scryer expression adapts [jagu-sayan's nixpkgs PR #546327](https://github.com/NixOS/nixpkgs/pull/546327), specifically [commit `cc7f93e`](https://github.com/jagu-sayan/nixpkgs/blob/cc7f93eadc7f0667197cb9d2b55977847b8e8d31/pkgs/by-name/sc/scryer/package.nix). The Nixpkgs copyright and permission notice are preserved in this repository's license. Its 0.17.2 hashes and test skips are not reused for 0.21.15.

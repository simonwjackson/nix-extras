"""Install ReSkate into a Steam copy of skate. and set its launch option.

ReSkate's client is two Windows files, ReSkateLauncher.exe and ReSkate.dll,
that must sit beside Skate.exe. Steam owns that folder, so Nix cannot. This
program copies the files from the Nix store into it, then writes the launch
option that swaps EA's anti-cheat launcher for ReSkate's under Proton.

Exit codes:
  0  everything is in place
  1  bad usage or an unexpected error
  2  skate. is not installed in any Steam library
  3  the launch option was not written (Steam is running, or the game
     already has a different launch option and --force was not given)
"""

import argparse
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

import vdf

APP_ID = "3354750"
CLIENT_FILES = ("ReSkateLauncher.exe", "ReSkate.dll")
LAUNCH_OPTIONS = (
    "bash -c 'exec \"${@/EAAntiCheat.GameServiceLauncher.exe/"
    "ReSkateLauncher.exe}\"' -- %command%"
)

EXIT_OK = 0
EXIT_NOT_INSTALLED = 2
EXIT_LAUNCH_OPTIONS = 3


def say(message):
    print(f"reskate-install: {message}")


def default_steam_dirs():
    home = Path.home()
    return [home / ".local/share/Steam", home / ".steam/steam"]


def load_vdf(path):
    with open(path, encoding="utf-8", errors="replace") as handle:
        return vdf.load(handle, mapper=vdf.VDFDict)


def get_ci(mapping, key):
    """Steam writes some keys in mixed case ("apps" and "Apps")."""
    for candidate in mapping.keys():
        if candidate.lower() == key.lower():
            return mapping[candidate]
    return None


def library_paths(steam_dir):
    paths = [steam_dir]
    folders = steam_dir / "steamapps/libraryfolders.vdf"
    if folders.is_file():
        root = get_ci(load_vdf(folders), "libraryfolders") or {}
        for entry in root.values():
            if isinstance(entry, dict) and entry.get("path"):
                paths.append(Path(entry["path"]))
    unique = []
    for path in paths:
        resolved = path.resolve()
        if resolved not in unique:
            unique.append(resolved)
    return unique


def find_game(steam_dirs):
    """Return (game_dir, build_id) for the first library that has skate."""
    for steam_dir in steam_dirs:
        if not steam_dir.is_dir():
            continue
        for library in library_paths(steam_dir):
            manifest = library / f"steamapps/appmanifest_{APP_ID}.acf"
            if not manifest.is_file():
                continue
            state = get_ci(load_vdf(manifest), "AppState") or {}
            game_dir = library / "steamapps/common" / state.get("installdir", "")
            if (game_dir / "Skate.exe").is_file():
                return game_dir, state.get("buildid", "unknown")
    return None


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def install_files(payload, game_dir, force):
    for name in CLIENT_FILES:
        source = payload / name
        target = game_dir / name
        if target.exists() and not force:
            if sha256(target) == sha256(source):
                say(f"{name} is current")
            else:
                # The launcher updates itself and ReSkate.dll in place. A
                # different file is most likely newer, so keep it.
                say(f"{name} differs from this flake's copy; kept it "
                    "(the launcher updates itself; --force replaces it)")
            continue
        temporary = target.with_name(target.name + ".reskate-tmp")
        shutil.copyfile(source, temporary)
        os.chmod(temporary, 0o644)
        os.replace(temporary, target)
        say(f"installed {target}")


def steam_is_running():
    for comm in Path("/proc").glob("[0-9]*/comm"):
        try:
            if comm.read_text().strip() in ("steam", "steamwebhelper"):
                return True
        except OSError:
            continue
    return False


def app_section(config):
    """Return the apps table of a localconfig.vdf, or None."""
    node = config
    for key in ("UserLocalConfigStore", "Software", "Valve", "Steam", "apps"):
        node = get_ci(node, key) if isinstance(node, dict) else None
        if node is None:
            return None
    return node


def write_launch_options(steam_dirs, force):
    """Return True when every Steam user has the ReSkate launch option."""
    configs = []
    for steam_dir in steam_dirs:
        for path in sorted(steam_dir.glob("userdata/*/config/localconfig.vdf")):
            # userdata/0 is Steam's anonymous user, not a person.
            if path.parent.parent.name != "0" and path.resolve() not in configs:
                configs.append(path.resolve())
    if not configs:
        say("no Steam user config found; start Steam and sign in once")
        return False

    pending = []
    complete = True
    for path in configs:
        config = load_vdf(path)
        apps = app_section(config)
        if apps is None:
            say(f"{path} has no apps table; launch skate. once from Steam")
            complete = False
            continue
        if APP_ID not in apps:
            apps[APP_ID] = vdf.VDFDict()
        current = apps[APP_ID].get("LaunchOptions", "")
        if current == LAUNCH_OPTIONS:
            say(f"launch option already set in {path}")
            continue
        if current and not force:
            say(f"{path} already has a different launch option for skate.:")
            say(f"  {current}")
            say("  kept it; --force replaces it")
            complete = False
            continue
        pending.append((path, config, apps[APP_ID]))

    if pending and steam_is_running():
        say("Steam is running and rewrites its config on exit; "
            "quit Steam and run this again")
        return False

    for path, config, app in pending:
        # VDFDict replaces the first "LaunchOptions" or appends a new one.
        app["LaunchOptions"] = LAUNCH_OPTIONS
        backup = path.with_name(path.name + ".reskate-backup")
        if not backup.exists():
            shutil.copy2(path, backup)
        temporary = path.with_name(path.name + ".reskate-tmp")
        with open(temporary, "w", encoding="utf-8") as handle:
            vdf.dump(config, handle, pretty=True)
        os.replace(temporary, path)
        say(f"set the launch option in {path}")
    return complete


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="reskate-install",
        description="Put ReSkate beside Skate.exe and set the Steam "
                    "launch option that starts it under Proton.",
    )
    parser.add_argument(
        "--steam-dir", type=Path, action="append",
        help="Steam root (default: ~/.local/share/Steam and ~/.steam/steam)",
    )
    parser.add_argument(
        "--force", action="store_true",
        help="replace different ReSkate files and an existing launch option",
    )
    parser.add_argument(
        "--skip-launch-options", action="store_true",
        help="copy the files only; set the launch option yourself",
    )
    parser.add_argument("--payload", type=Path, help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    payload = args.payload or Path(os.environ["RESKATE_PAYLOAD"])
    steam_dirs = [path.expanduser() for path in
                  (args.steam_dir or default_steam_dirs())]
    pins = json.loads((payload / "launcher.json").read_text())
    supported_build = pins["game"]["build_id"]

    found = find_game(steam_dirs)
    if found is None:
        say(f"skate. (Steam app {APP_ID}) is not installed in any Steam "
            "library. Install it in Steam first:")
        say(f"  steam steam://install/{APP_ID}")
        return EXIT_NOT_INSTALLED
    game_dir, build_id = found
    say(f"found skate. in {game_dir} (Steam build {build_id})")
    if build_id != supported_build:
        say(f"ReSkate {pins['runtime']['version']} supports build "
            f"{supported_build} only. On first start the launcher asks you "
            "to sign in to Steam and downloads that build.")

    install_files(payload, game_dir, args.force)

    if args.skip_launch_options:
        say("skipped the launch option; set it in Steam > skate. > "
            "Properties > Launch Options:")
        say(f"  {LAUNCH_OPTIONS}")
        return EXIT_OK
    if not write_launch_options(steam_dirs, args.force):
        say("the launch option to use is:")
        say(f"  {LAUNCH_OPTIONS}")
        return EXIT_LAUNCH_OPTIONS
    say("done; press Play on skate. in Steam")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())

# Exercises reskate-install against a real Steam directory layout in a temp
# folder. Run by `nix flake check`; $reskate is the package under test.
set -euo pipefail

export HOME=$PWD/home
steam=$HOME/.local/share/Steam
library=$PWD/library
game=$library/steamapps/common/skate
user=$steam/userdata/80924811/config
launch_option="bash -c 'exec \"\${@/EAAntiCheat.GameServiceLauncher.exe/ReSkateLauncher.exe}\"' -- %command%"

fail() { echo "FAIL: $*" >&2; exit 1; }

expect_status() {
  local want=$1; shift
  set +e; "$@" > out.log 2>&1; local got=$?; set -e
  cat out.log
  [ "$got" -eq "$want" ] || fail "expected exit $want, got $got from: $*"
}

mkdir -p "$steam/steamapps" "$user" "$steam/userdata/0/config"
cat > "$steam/steamapps/libraryfolders.vdf" <<EOF
"libraryfolders"
{
	"0"
	{
		"path"		"$steam"
	}
	"1"
	{
		"path"		"$library"
	}
}
EOF
cat > "$user/localconfig.vdf" <<'EOF'
"UserLocalConfigStore"
{
	"Software"
	{
		"Valve"
		{
			"Steam"
			{
				"apps"
				{
					"620"
					{
						"LaunchOptions"		"+map sp_a1_intro1"
					}
				}
			}
		}
	}
}
EOF
cp "$user/localconfig.vdf" "$steam/userdata/0/config/localconfig.vdf"

echo "== the game is not installed: exit 2, nothing written"
expect_status 2 reskate-install
grep -q "steam://install/3354750" out.log || fail "no install hint"

echo "== the game is installed at an older build"
mkdir -p "$game"
touch "$game/Skate.exe"
cat > "$library/steamapps/appmanifest_3354750.acf" <<'EOF'
"AppState"
{
	"appid"		"3354750"
	"name"		"skate."
	"installdir"		"skate"
	"buildid"		"1"
}
EOF
expect_status 0 reskate-install
grep -q "supports build 25414733 only" out.log || fail "no build warning"
for f in ReSkateLauncher.exe ReSkate.dll; do
  cmp "$game/$f" "$reskate/share/reskate/$f" || fail "$f not installed"
done
python3 - "$user/localconfig.vdf" "$launch_option" <<'EOF'
import sys, vdf
config = vdf.load(open(sys.argv[1]))
apps = config["UserLocalConfigStore"]["Software"]["Valve"]["Steam"]["apps"]
assert apps["3354750"]["LaunchOptions"] == sys.argv[2], apps["3354750"]
assert apps["620"]["LaunchOptions"] == "+map sp_a1_intro1", "clobbered 620"
EOF
[ -f "$user/localconfig.vdf.reskate-backup" ] || fail "no backup"
cmp -s "$steam/userdata/0/config/localconfig.vdf" "$user/localconfig.vdf.reskate-backup" \
  || fail "userdata/0 was changed"

echo "== a second run changes nothing"
expect_status 0 reskate-install
grep -q "launch option already set" out.log || fail "not idempotent"

echo "== a self-updated launcher is kept"
echo newer > "$game/ReSkateLauncher.exe"
expect_status 0 reskate-install
[ "$(cat "$game/ReSkateLauncher.exe")" = newer ] || fail "downgraded the launcher"
expect_status 0 reskate-install --force
cmp "$game/ReSkateLauncher.exe" "$reskate/share/reskate/ReSkateLauncher.exe" || fail "--force"

echo "== a different launch option is kept without --force"
python3 - "$user/localconfig.vdf" <<'EOF'
import sys, vdf
config = vdf.load(open(sys.argv[1]))
apps = config["UserLocalConfigStore"]["Software"]["Valve"]["Steam"]["apps"]
apps["3354750"]["LaunchOptions"] = "gamescope -- %command%"
vdf.dump(config, open(sys.argv[1], "w"), pretty=True)
EOF
grep -q 'gamescope -- %command%' "$user/localconfig.vdf" || fail "test setup"
expect_status 3 reskate-install
grep -q 'gamescope -- %command%' "$user/localconfig.vdf" || fail "clobbered without --force"

echo "== Steam running blocks the write"
# A real process whose name is "steam", which is what the installer looks for.
cp "$(command -v bash)" ./steam
./steam -c 'while :; do sleep 1; done' &
steam_pid=$!
expect_status 3 reskate-install --force
grep -q "Steam is running" out.log || fail "did not detect Steam"
kill "$steam_pid"; wait "$steam_pid" 2>/dev/null || true

echo "== with Steam closed, --force writes it"
expect_status 0 reskate-install --force
grep -qF 'ReSkateLauncher.exe}\"' "$user/localconfig.vdf" || fail "escaping"

echo "PASS"

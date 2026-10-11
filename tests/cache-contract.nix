{ pkgs, publisher }:
let
  fixture = pkgs.runCommand "nix-extras-cache-fixture" { } ''
    mkdir -p "$out"
    printf 'signed cache fixture\n' > "$out/value"
  '';
  registration = pkgs.closureInfo { rootPaths = [ fixture ]; };
  identity = pkgs.writeText "cache-identity.json" (builtins.toJSON (import ../cache/identity.nix));
in
pkgs.runCommand "nix-extras-cache-contract"
  {
    nativeBuildInputs = [
      pkgs.nix
      pkgs.python3
    ];
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    python3 ${./cache-contract.py} ${fixture} ${registration}/registration ${publisher} ${../flake.nix} ${identity} ${../scripts/publish-cache.py}
    touch "$out"
  ''

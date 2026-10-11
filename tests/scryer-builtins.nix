{ pkgs, package }:
pkgs.runCommand "scryer-builtin-authentication-tests"
  {
    nativeBuildInputs = with pkgs; [
      python3
      cosign
      b3sum
      zstd
      openssl
    ];
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    python3 ${./scryer-builtins.py} ${../pkgs/scryer/assemble-builtins.py} \
      --source ${package.src} --metadata ${../pkgs/scryer/builtin-metadata} --output unused \
      --trust-root ${package.builtinInputs.trustRoot} \
      --newznab-wasm ${package.builtinInputs.newznabWasm} \
      --newznab-bundle ${package.builtinInputs.newznabBundle} \
      --torznab-wasm ${package.builtinInputs.torznabWasm} \
      --torznab-bundle ${package.builtinInputs.torznabBundle}
    touch "$out"
  ''

# Adapted from jagu-sayan's NixOS/nixpkgs PR #546327 (MIT).
# https://github.com/NixOS/nixpkgs/pull/546327
{
  lib,
  rustPlatform,
  src,
  builtinInputs,
  runCommand,
  python3,
  cosign,
  b3sum,
  zstd,
  openssl,
  buildNpmPackage,
  nodejs_24,
  nasm,
  cmake,
  perl,
  pkg-config,
  cacert,
}:
let
  version = "0.21.15";
  # Do not tie these inputs to the enclosing flake source tree. Cache and
  # documentation changes must not change the application derivation.
  materializer = builtins.path {
    path = ./assemble-builtins.py;
    name = "assemble-scryer-builtins.py";
  };
  builtinMetadata = builtins.path {
    path = ./builtin-metadata;
    name = "scryer-builtin-metadata";
  };
  builtinAssets =
    runCommand "scryer-${version}-verified-builtins"
      {
        nativeBuildInputs = [
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
        python3 ${materializer} \
          --source ${src} --metadata ${builtinMetadata} --output "$out" \
          --trust-root ${builtinInputs.trustRoot} \
          --newznab-wasm ${builtinInputs.newznabWasm} \
          --newznab-bundle ${builtinInputs.newznabBundle} \
          --torznab-wasm ${builtinInputs.torznabWasm} \
          --torznab-bundle ${builtinInputs.torznabBundle}
      '';
  webui = buildNpmPackage {
    pname = "scryer-webui";
    inherit version src;
    nodejs = nodejs_24;
    sourceRoot = "${src.name or "source"}/apps/scryer-web";
    npmDepsHash = "sha256-gnF5wm5f0yNtc12sWHFsDjMFTNPAZTKBJ15n3wLFOdU=";
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -r dist/. "$out/"
      runHook postInstall
    '';
  };
in
rustPlatform.buildRustPackage {
  pname = "scryer";
  inherit version src;
  cargoHash = "sha256-8ZzlXODh1l9DH1Bsz3sobH/BaS5zrZXnBNzkjcLlkGs=";
  nativeBuildInputs = [
    nasm
    cmake
    perl
    pkg-config
  ];
  nativeCheckInputs = [ cacert ];
  postPatch = ''
    mkdir -p crates/scryer-plugins/builtins
    cp -r ${builtinAssets}/. crates/scryer-plugins/builtins/
  '';
  cargoBuildFlags = [
    "-p"
    "scryer"
    "--bin"
    "scryer"
  ];
  cargoTestFlags = [
    "-p"
    "scryer-release-parser"
    "--lib"
  ];
  env = {
    SCRYER_EMBED_UI_DIR = webui;
    CARGO_PROFILE_RELEASE_LTO = "thin";
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
  };

  passthru = { inherit webui builtinAssets builtinInputs; };
  meta = {
    description = "Self-hosted media management for movies, series, and anime";
    homepage = "https://www.scryer.media";
    license = lib.licenses.gpl3Only;
    mainProgram = "scryer";
    platforms = [ "x86_64-linux" ];
  };
}

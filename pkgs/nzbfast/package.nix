{
  lib,
  rustPlatform,
  src,
  cmake,
  perl,
  pkg-config,
  installShellFiles,
}:
rustPlatform.buildRustPackage {
  pname = "nzbfast";
  version = "1.7.1";
  inherit src;
  cargoHash = "sha256-x+VNnU+vH0XkYqBr/9urRgvMlEAXdwreJdCo4uT3Mxk=";

  nativeBuildInputs = [
    cmake
    perl
    pkg-config
    installShellFiles
  ];
  cargoBuildFlags = [
    "-p"
    "nzbfast"
    "--bin"
    "nzbfast"
  ];
  cargoTestFlags = [
    "-p"
    "nzbkit-base"
    "--lib"
    "yenc"
  ];
  env = {
    CARGO_PROFILE_RELEASE_LTO = "thin";
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS = "16";
    NZBFAST_NO_ENRICH = "1";
  };

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    "$out/bin/nzbfast" --version | grep '1.7.1'
    "$out/bin/nzbfast" serve --help > /dev/null
    runHook postInstallCheck
  '';

  meta = {
    description = "Usenet downloader with streaming verification and extraction";
    homepage = "https://github.com/nzbfast/nzbfast";
    license = lib.licenses.gpl3Plus;
    mainProgram = "nzbfast";
    platforms = [ "x86_64-linux" ];
  };
}

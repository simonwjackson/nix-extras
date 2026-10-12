# ReSkate's client from the upstream release zip, plus `reskate-install`.
#
# The client is two prebuilt Windows files that run inside skate. under
# Proton. Upstream builds them with MSVC only, so this expression does not
# build them. It keeps them in the store, and `reskate-install` copies them
# beside Skate.exe in the Steam library, which Steam owns and Nix cannot.
{
  lib,
  stdenvNoCC,
  src,
  unzip,
  makeWrapper,
  python3,
}:
let
  python = python3.withPackages (ps: [ ps.vdf ]);
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "reskate";
  version = "2.0.7";
  inherit src;

  nativeBuildInputs = [
    unzip
    makeWrapper
  ];

  # The zip stores "licenses\x.txt" with Windows separators. unzip converts
  # them and exits 1 to warn about it; any other status is a real failure.
  unpackPhase = ''
    runHook preUnpack
    mkdir source
    unzip -q "$src" -d source || [ $? -eq 1 ]
    cd source
    runHook postUnpack
  '';

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    payload=$out/share/reskate
    install -Dm644 -t $payload ReSkateLauncher.exe ReSkate.dll launcher.json LICENSE.txt
    cp -r licenses $payload/licenses

    install -Dm644 ${./reskate_install.py} $out/libexec/reskate_install.py
    makeWrapper ${python.interpreter} $out/bin/reskate-install \
      --add-flags $out/libexec/reskate_install.py \
      --set RESKATE_PAYLOAD $payload
    runHook postInstall
  '';

  # The release's launcher.json pins the files of the same version. A source
  # input that does not match `version` fails here.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    grep -q '"version":  "${finalAttrs.version}"' $out/share/reskate/launcher.json
    $out/bin/reskate-install --help > /dev/null
    runHook postInstallCheck
  '';

  meta = {
    description = "ReSkate client (offline play, lobbies, mods) for skate. on Steam, with an installer";
    homepage = "https://github.com/Dingo-Shenanigans/ReSkate";
    license = lib.licenses.gpl3Only;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = [ "x86_64-linux" ];
    mainProgram = "reskate-install";
  };
})

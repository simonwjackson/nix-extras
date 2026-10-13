# Upstream's signed release binary. The source build cannot enroll with the
# Scryer Metadata Gateway: upstream embeds the SMG registration secret at
# compile time from its CI secrets (crates/scryer/build.rs:123), so a source
# build gets 401 from SMG and never hydrates title metadata.
#
# Verification runs in the network-isolated sandbox:
#   1. cosign checks the checksum file's Sigstore bundle against the pinned
#      TUF trust root, the GitHub Actions issuer, and the exact release
#      workflow identity for this tag.
#   2. The tarball's SHA-256 must match its line in that checksum file.
{
  lib,
  runCommand,
  cosign,
  version,
  tarball,
  checksums,
  checksumsBundle,
  trustRoot,
}:
let
  asset = "scryer-linux-x86_64-portable.tar.gz";
  identity = "https://github.com/scryer-media/scryer/.github/workflows/scryer.yml@refs/tags/scryer-v${version}";
in
runCommand "scryer-${version}"
  {
    nativeBuildInputs = [ cosign ];
    passthru = {
      inherit
        tarball
        checksums
        checksumsBundle
        trustRoot
        ;
    };
    meta = {
      description = "Self-hosted media management for movies, series, and anime (signed upstream release)";
      homepage = "https://www.scryer.media";
      license = lib.licenses.gpl3Only;
      mainProgram = "scryer";
      platforms = [ "x86_64-linux" ];
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    cosign verify-blob \
      --bundle ${checksumsBundle} \
      --trusted-root ${trustRoot} \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      --certificate-identity ${lib.escapeShellArg identity} \
      ${checksums}
    expected=$(awk '$2 == "${asset}" { print $1 }' ${checksums})
    test -n "$expected"
    echo "$expected  ${tarball}" | sha256sum --check
    mkdir -p unpack "$out/bin"
    tar -xzf ${tarball} -C unpack
    install -Dm555 unpack/scryer "$out/bin/scryer"
    test "$("$out/bin/scryer" --version)" = "scryer ${version}"
  ''

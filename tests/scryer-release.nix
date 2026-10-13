# The signed release package must refuse a tampered checksum file or a
# release-workflow identity from another tag.
{ pkgs, package }:
let
  inherit (package)
    tarball
    checksums
    checksumsBundle
    trustRoot
    ;
  tamperedChecksums = pkgs.runCommand "scryer-checksums-tampered" { } ''
    sed 's/^0/1/' ${checksums} > "$out"
  '';
  build =
    overrides:
    pkgs.callPackage ../pkgs/scryer/release.nix (
      {
        version = "0.21.15";
        inherit
          tarball
          checksums
          checksumsBundle
          trustRoot
          ;
      }
      // overrides
    );
  tampered = pkgs.testers.testBuildFailure (build {
    checksums = tamperedChecksums;
  });
  wrongTag = pkgs.testers.testBuildFailure (build {
    version = "0.21.14";
  });
in
pkgs.runCommand "scryer-release-verification" { } ''
  test -x ${package}/bin/scryer
  grep -q . ${tampered}/testBuildFailure.log
  grep -q . ${wrongTag}/testBuildFailure.log
  echo "signed release accepted; tampered checksums and wrong tag refused" > "$out"
''

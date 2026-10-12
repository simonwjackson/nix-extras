{ pkgs, package }:
pkgs.runCommand "reskate-install-test"
  {
    nativeBuildInputs = [
      package
      (pkgs.python3.withPackages (ps: [ ps.vdf ]))
    ];
    reskate = package;
  }
  ''
    mkdir work && cd work
    bash ${./reskate-install.sh}
    touch "$out"
  ''

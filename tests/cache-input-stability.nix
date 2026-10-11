{
  pkgs,
  src,
  builtinInputs,
}:
let
  # Different enclosing store roots reproduce a changed flake source tree.
  left = builtins.path {
    path = ../pkgs/scryer;
    name = "scryer-cache-left";
  };
  right = builtins.path {
    path = ../pkgs/scryer;
    name = "scryer-cache-right";
  };
  first = pkgs.callPackage "${left}/package.nix" { inherit src builtinInputs; };
  second = pkgs.callPackage "${right}/package.nix" { inherit src builtinInputs; };
in
assert first.drvPath == second.drvPath;
pkgs.runCommand "scryer-cache-input-stability" { } ''
  touch "$out"
''

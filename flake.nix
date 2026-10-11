{
  description = "Community Nix packages, overlays, and NixOS modules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nzbfast-src = {
      url = "github:nzbfast/nzbfast/v1.7.1";
      flake = false;
    };
    scryer-src = {
      url = "github:scryer-media/scryer/scryer-v0.21.14";
      flake = false;
    };
    scryer-newznab-wasm = {
      type = "file";
      url = "https://cdn.scryer.media/scryer/plugins-v3/newznab/v2.2.3/plugin-v3.5cbd81043744cd0a9342e9d4cc6730b67390575adcc8b782f13a9e2f86be2e17.wasm.zst";
      flake = false;
    };
    scryer-newznab-bundle = {
      type = "file";
      url = "https://cdn.scryer.media/scryer/plugins-v3/newznab/v2.2.3/plugin-v3.5cbd81043744cd0a9342e9d4cc6730b67390575adcc8b782f13a9e2f86be2e17.wasm.zst.bundle.zst";
      flake = false;
    };
    scryer-torznab-wasm = {
      type = "file";
      url = "https://cdn.scryer.media/scryer/plugins-v3/torznab/v2.2.3/plugin-v3.b9df6ec430d6b1a8546ca094817f6b383369fd728a7d8077899655bb9237572f.wasm.zst";
      flake = false;
    };
    scryer-torznab-bundle = {
      type = "file";
      url = "https://cdn.scryer.media/scryer/plugins-v3/torznab/v2.2.3/plugin-v3.b9df6ec430d6b1a8546ca094817f6b383369fd728a7d8077899655bb9237572f.wasm.zst.bundle.zst";
      flake = false;
    };
    scryer-trust-root = {
      type = "file";
      url = "https://tuf-repo-cdn.sigstore.dev/targets/6494e21ea73fa7ee769f85f57d5a3e6a08725eae1e38c755fc3517c9e6bc0b66.trusted_root.json";
      flake = false;
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      nzbfast-src,
      scryer-src,
      ...
    }:
    let
      systems = [ "x86_64-linux" ];
      forSystems = nixpkgs.lib.genAttrs systems;
      packagesFor = pkgs: {
        nzbfast = pkgs.callPackage ./pkgs/nzbfast/package.nix { src = nzbfast-src; };
        scryer = pkgs.callPackage ./pkgs/scryer/package.nix {
          src = scryer-src;
          builtinInputs = {
            newznabWasm = inputs.scryer-newznab-wasm;
            newznabBundle = inputs.scryer-newznab-bundle;
            torznabWasm = inputs.scryer-torznab-wasm;
            torznabBundle = inputs.scryer-torznab-bundle;
            trustRoot = inputs.scryer-trust-root;
          };
        };
      };
    in
    {
      packages = forSystems (system: packagesFor nixpkgs.legacyPackages.${system});
      overlays.default = final: _prev: packagesFor final;
      formatter = forSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
      nixosModules = {
        nzbfast = { lib, pkgs, ... }: {
          imports = [ ./modules/nzbfast.nix ];
          services.nzbfast.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.nzbfast;
        };
        scryer = { lib, pkgs, ... }: {
          imports = [ ./modules/scryer.nix ];
          services.scryer.package = lib.mkDefault self.packages.${pkgs.stdenv.hostPlatform.system}.scryer;
        };
      };
      checks = forSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          inherit (self.packages.${system}) nzbfast scryer;
          scryer-builtins = import ./tests/scryer-builtins.nix {
            inherit pkgs;
            package = self.packages.${system}.scryer;
          };
          nzbfast-service = import ./tests/nzbfast.nix {
            inherit pkgs;
            module = self.nixosModules.nzbfast;
          };
          scryer-service = import ./tests/scryer.nix {
            inherit pkgs;
            module = self.nixosModules.scryer;
          };
          module-options = import ./tests/module-options.nix {
            inherit pkgs nixpkgs;
            modules = self.nixosModules;
            packages = self.packages.${system};
          };
        }
      );
    };
}

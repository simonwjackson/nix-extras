{
  description = "Community Nix packages, overlays, and NixOS modules";

  nixConfig = {
    # Nix requires literal flake settings, not imported expressions.
    extra-substituters = "https://github.com/simonwjackson/nix-extras/releases/download/cache/";
    extra-trusted-public-keys = "nix-extras-ci-1:+Vcq7i6dPWOsOZjQwOduCEZOZZJznS/XfOcNUhFmg3Q=";
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    cache-publisher = {
      type = "file";
      url = "https://raw.githubusercontent.com/korri-os/korri/e6902f0f3c7c2081db033b31c4cd6557b254537a/nix/cache/github-cache.py";
      flake = false;
    };
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
      cacheIdentity = import ./cache/identity.nix;
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
      cache = cacheIdentity;
      packages = forSystems (system: packagesFor nixpkgs.legacyPackages.${system});
      apps = forSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          publisher = pkgs.writeShellApplication {
            name = "nix-extras-cache-publish";
            runtimeInputs = [
              pkgs.nix
              pkgs.python3
              pkgs.gh
              pkgs.git
            ];
            text = ''
              exec python3 ${./scripts/publish-cache.py} --publisher ${inputs.cache-publisher} --verify-script ${./scripts/verify-cache.py} "$@"
            '';
          };
        in
        {
          cache-publish = {
            type = "app";
            program = "${publisher}/bin/nix-extras-cache-publish";
          };
        }
      );
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
          cache-contract = import ./tests/cache-contract.nix {
            inherit pkgs;
            publisher = inputs.cache-publisher;
          };
          cache-input-stability = import ./tests/cache-input-stability.nix {
            inherit pkgs;
            src = scryer-src;
            inherit (self.packages.${system}.scryer) builtinInputs;
          };
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

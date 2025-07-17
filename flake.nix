{
  description = "A Nix-based continuous build system";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05-small";

  inputs.nix = {
    url = "github:NixOS/nix/2.29-maintenance";
    # We want to control the deps precisely
    flake = false;
  };

  inputs.nix-eval-jobs = {
    url = "github:nix-community/nix-eval-jobs";
    # We want to control the deps precisely
    flake = false;
  };

  outputs = { self, nixpkgs, nix, nix-eval-jobs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
    in
    rec {

      # A Nixpkgs overlay that provides a 'hydra' package.
      overlays.default = final: prev: {
        nixDependenciesForHydra = final.lib.makeScope final.newScope
          (import (nix + "/packaging/dependencies.nix") {
            pkgs = final;
            inherit (final) stdenv;
            inputs = {};
          });
        nixComponentsForHydra = final.lib.makeScope final.nixDependenciesForHydra.newScope
          (import (nix + "/packaging/components.nix") {
            officialRelease = true;
            inherit (final) lib;
            pkgs = final;
            src = nix;
            maintainers = [ ];
          });
        nix-eval-jobs = final.callPackage nix-eval-jobs {
          nixComponents = final.nixComponentsForHydra;
        };
        hydra = final.callPackage ./package.nix {
          inherit (final.lib) fileset;
          rawSrc = self;
          nixComponents = final.nixComponentsForHydra;
        };
      };

      hydraJobs = {
        build = forEachSystem (system: packages.${system}.hydra);

        buildNoTests = forEachSystem (system:
          packages.${system}.hydra.overrideAttrs (_: {
            doCheck = false;
          })
        );

        manual = forEachSystem (system: let
          pkgs = nixpkgs.legacyPackages.${system};
          hydra = self.packages.${pkgs.hostPlatform.system}.hydra;
        in
          pkgs.runCommand "hydra-manual-${hydra.version}" { }
            ''
              mkdir -p $out/share
              cp -prvd ${hydra.doc}/share/doc $out/share/

              mkdir $out/nix-support
              echo "doc manual $out/share/doc/hydra" >> $out/nix-support/hydra-build-products
            '');

        tests = import ./nixos-tests.nix {
          inherit forEachSystem nixpkgs nixosModules;
        };

        container = nixosConfigurations.container.config.system.build.toplevel;
      };

      checks = forEachSystem (system: {
        build = hydraJobs.build.${system};
        install = hydraJobs.tests.install.${system};
        validate-openapi = hydraJobs.tests.validate-openapi.${system};
      });

      packages = forEachSystem (system: let
        inherit (nixpkgs) lib;
        pkgs = nixpkgs.legacyPackages.${system};
        nixDependencies = lib.makeScope pkgs.newScope
          (import (nix + "/packaging/dependencies.nix") {
            inherit pkgs;
            inherit (pkgs) stdenv;
            inputs = {};
          });
        nixComponents = lib.makeScope nixDependencies.newScope
          (import (nix + "/packaging/components.nix") {
            officialRelease = true;
            inherit lib pkgs;
            src = nix;
            maintainers = [ ];
          });
      in {
        nix-eval-jobs = pkgs.callPackage nix-eval-jobs {
          inherit nixComponents;
        };
        hydra = pkgs.callPackage ./package.nix {
          inherit (nixpkgs.lib) fileset;
          inherit nixComponents;
          inherit (self.packages.${system}) nix-eval-jobs;
          rawSrc = self;
        };
        default = self.packages.${system}.hydra;
      });

      nixosModules = import ./nixos-modules {
        inherit self;
      };

      nixosConfigurations.container = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules =
          [
            self.nixosModules.hydra
            self.nixosModules.hydraTest
            self.nixosModules.hydraProxy
            {
              system.configurationRevision = self.lastModifiedDate;

              boot.isContainer = true;
              networking.useDHCP = false;
              networking.firewall.allowedTCPPorts = [ 80 ];
              networking.hostName = "hydra";

              services.hydra-dev.useSubstitutes = true;
            }
          ];
      };

    };
}

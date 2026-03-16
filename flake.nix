{
  description = "A Nix-based continuous build system";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11-small";

  inputs.nix = {
    url = "github:NixOS/nix/2.34-maintenance";
    # We want to control the deps precisely
    flake = false;
  };

  inputs.nix-eval-jobs = {
    url = "github:NixOS/nix-eval-jobs/v2.34.1";
    # We want to control the deps precisely
    flake = false;
  };

  outputs = { self, nixpkgs, nix, nix-eval-jobs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;

      version = "${builtins.readFile ./version.txt}.${builtins.substring 0 8 (self.lastModifiedDate or "19700101")}.${self.shortRev or "DIRTY"}";

      mkHydraComponents = { pkgs, nixComponents }:
        pkgs.lib.makeScope pkgs.newScope (self': {
          inherit version;
          nix-eval-jobs = self'.callPackage nix-eval-jobs {
            inherit nixComponents;
          };
          hydra = self'.callPackage ./subprojects/hydra/package.nix {
            inherit nixComponents;
            rawSrc = self;
          };
          hydra-tests = self'.callPackage ./subprojects/hydra-tests/package.nix {
            inherit nixComponents;
          };
          hydra-manual = self'.callPackage ./subprojects/hydra-manual/package.nix {
          };
          hydra-linters = self'.callPackage ./subprojects/hydra-linters/package.nix {
          };
          hydra-queue-runner = self'.callPackage ./subprojects/hydra-queue-runner/package.nix {
            inherit nixComponents;
          };
        });
    in
    rec {

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
        hydraComponents = mkHydraComponents {
          pkgs = final;
          nixComponents = final.nixComponentsForHydra;
        };
        inherit (final.hydraComponents) hydra hydra-tests hydra-manual hydra-linters hydra-queue-runner;
      };

      hydraJobs = {
        build = forEachSystem (system: packages.${system}.hydra);

        unitTests = forEachSystem (system: packages.${system}.hydra-tests);

        manual = forEachSystem (system: packages.${system}.hydra-manual);

        linters = forEachSystem (system: packages.${system}.hydra-linters);

        queueRunner = forEachSystem (system: packages.${system}.hydra-queue-runner);

        nixosTests = import ./nixos-tests.nix {
          inherit forEachSystem nixpkgs nixosModules;
        };

        container = nixosConfigurations.container.config.system.build.toplevel;
      };

      checks = forEachSystem (system: {
        build = hydraJobs.build.${system};
        install = hydraJobs.nixosTests.install.${system};
        validate-openapi = hydraJobs.nixosTests.validate-openapi.${system};
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
        hydraComponents = mkHydraComponents { inherit pkgs nixComponents; };
      in hydraComponents // {
        default = hydraComponents.hydra-tests;
      });

      devShells = forEachSystem (system: {
        default = import ./packaging/dev-shell.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (self.packages.${system}) hydra hydra-tests hydra-manual hydra-linters hydra-queue-runner;
        };
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

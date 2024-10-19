{
  description = "A Nix-based continuous build system";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05-small";

  inputs.libgit2 = { url = "github:libgit2/libgit2/v1.8.1"; flake = false; };
  inputs.nix.url = "github:NixOS/nix/2.24-maintenance";
  inputs.nix.inputs.nixpkgs.follows = "nixpkgs";
  inputs.nix.inputs.libgit2.follows = "libgit2";

  # hide nix dev tooling from our lock file
  inputs.nix.inputs.flake-parts.follows = "";
  inputs.nix.inputs.git-hooks-nix.follows = "";
  inputs.nix.inputs.nixpkgs-regression.follows = "";
  inputs.nix.inputs.nixpkgs-23-11.follows = "";
  inputs.nix.inputs.flake-compat.follows = "";

  outputs = { self, nixpkgs, nix, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forEachSystem = nixpkgs.lib.genAttrs systems;
    in
    rec {

      # A Nixpkgs overlay that provides a 'hydra' package.
      overlays.default = final: prev: {
        hydra = final.callPackage ./package.nix {
          inherit (nixpkgs.lib) fileset;
          rawSrc = self;
          nix-perl-bindings = final.nixComponents.nix-perl-bindings;
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
              cp -prvd ${hydra}/share/doc $out/share/

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

      packages = forEachSystem (system: {
        hydra = nixpkgs.legacyPackages.${system}.callPackage ./package.nix {
          inherit (nixpkgs.lib) fileset;
          rawSrc = self;
          nix = nix.packages.${system}.nix;
          nix-perl-bindings = nix.hydraJobs.perlBindings.${system};
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

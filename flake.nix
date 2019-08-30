{
  description = "A Nix-based continuous build system";

  epoch = 201909;

  inputs.nix.uri = "nix/80c36d4562af71a90c67b3adb886a1003834890e";

  outputs = { self, nixpkgs, nix }@inputs:
    let
      nix = inputs.nix.hydraJobs.build.x86_64-linux // {
        perl-bindings = inputs.nix.hydraJobs.perlBindings.x86_64-linux;
      };
    in rec {

      hydraJobs = import ./release.nix {
        hydraSrc = self;
        nixpkgs = nixpkgs;
        inherit nix;
      };

      checks.build = hydraJobs.build.x86_64-linux;
      checks.install = hydraJobs.tests.install.x86_64-linux;

      packages.hydra = hydraJobs.build.x86_64-linux;

      defaultPackage = packages.hydra;

      devShell = (import ./release.nix {
        hydraSrc = self;
        nixpkgs = nixpkgs;
        shell = true;
        inherit nix;
      }).build.x86_64-linux;

    };
}

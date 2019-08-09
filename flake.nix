{
  name = "hydra";

  description = "A Nix-based continuous build system";

  epoch = 201906;

  inputs =
    [ "nixpkgs"
      "nix/ab16b3d076e9cd3ecfdcde128f43dd486b072557"
    ];

  outputs = inputs:
    let
      nix = inputs.nix.outputs.hydraJobs.build.x86_64-linux // {
        perl-bindings = inputs.nix.outputs.hydraJobs.perlBindings.x86_64-linux;
      };
    in rec {

      hydraJobs = import ./release.nix {
        hydraSrc = inputs.self;
        nixpkgs = inputs.nixpkgs;
        inherit nix;
      };

      checks.build = hydraJobs.build.x86_64-linux;
      checks.install = hydraJobs.tests.install.x86_64-linux;

      packages.hydra = hydraJobs.build.x86_64-linux;

      defaultPackage = packages.hydra;

      devShell = (import ./release.nix {
        hydraSrc = inputs.self;
        nixpkgs = inputs.nixpkgs;
        shell = true;
        inherit nix;
      }).build.x86_64-linux;

    };
}

{
  name = "hydra";

  description = "A Nix-based continuous build system";

  epoch = 2019;

  inputs = [ "nixpkgs" "nix" ];

  outputs = inputs: rec {

    hydraJobs = import ./release.nix {
      hydraSrc = inputs.self;
      nixpkgs = inputs.nixpkgs;
      nix = inputs.nix.outputs.hydraJobs.build.x86_64-linux // {
        perl-bindings = inputs.nix.outputs.hydraJobs.perlBindings.x86_64-linux;
      };
    };

    checks.build = hydraJobs.build.x86_64-linux;
    checks.install = hydraJobs.tests.install.x86_64-linux;

    packages.hydra = hydraJobs.build.x86_64-linux;

    defaultPackage = packages.hydra;

    devShell = (import ./release.nix {
      hydraSrc = inputs.self;
      nixpkgs = inputs.nixpkgs;
      shell = true;
    }).build.x86_64-linux;

  };
}

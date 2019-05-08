{
  name = "hydra";

  description = "A Nix-based continuous build system";

  epoch = 2019;

  requires = [ "nixpkgs" ];

  provides = deps: rec {

    hydraJobs = import ./release.nix {
      hydraSrc = deps.self;
      nixpkgs = deps.nixpkgs;
    };

    packages.hydra = hydraJobs.build.x86_64-linux;

    defaultPackage = packages.hydra;
  };
}

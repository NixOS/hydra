{
  name = "hydra";

  description = "A Nix-based continuous build system";

  epoch = 2019;

  requires = [ "nixpkgs" "nix" ];

  provides = deps: rec {

    hydraJobs = import ./release.nix {
      hydraSrc = deps.self;
      nixpkgs = deps.nixpkgs;
      nix = deps.nix.provides.hydraJobs.build.x86_64-linux // {
        perl-bindings = deps.nix.provides.hydraJobs.perlBindings.x86_64-linux;
      };
    };

    packages.hydra = hydraJobs.build.x86_64-linux;

    defaultPackage = packages.hydra;

    devShell = (import ./release.nix {
      hydraSrc = deps.self;
      nixpkgs = deps.nixpkgs;
      shell = true;
    }).build.x86_64-linux;

  };
}

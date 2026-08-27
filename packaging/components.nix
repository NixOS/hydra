# The scope holding every component hydra itself builds, on top of a Nix
# component set. `flake.nix` instantiates it once per package set.
{
  version,
  releaseVersion,
  crane,
  # Source of the `nix-eval-jobs` flake input, which carries its own package.nix.
  nix-eval-jobs-src,
  # The flake itself, which `hydra` wants unfiltered for its version stamp.
  rawSrc,
}:

{ pkgs, nixComponents }:

self': {
  inherit version releaseVersion;
  craneLib = crane.mkLib pkgs;
  rustWorkspace = self'.callPackage ./rust-workspace.nix { };
  hydra-cargo-deps = self'.rustWorkspace.cargoArtifacts;
  nix-eval-jobs = self'.callPackage nix-eval-jobs-src {
    inherit nixComponents;
  };
  nix-perl = self'.callPackage ../subprojects/nix-perl/package.nix {
    inherit (nixComponents) nix-store;
  };
  hydra = self'.callPackage ../subprojects/hydra/package.nix {
    inherit nixComponents rawSrc;
  };
  hydra-tests = self'.callPackage ../subprojects/hydra-tests/package.nix {
    inherit nixComponents;
  };
  hydra-manual = self'.callPackage ../subprojects/hydra-manual/package.nix { };
  hydra-linters = self'.callPackage ../subprojects/hydra-linters/package.nix { };
  inherit (self'.rustWorkspace) hydra-queue-runner hydra-builder;
}

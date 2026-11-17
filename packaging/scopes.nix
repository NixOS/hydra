# The `nixDependencies`, `nixComponents` and `hydraComponents` scopes for a
# given `pkgs`, spliced for cross compilation. Like Nix's own
# `packaging/scopes.nix`.
{
  lib,
  version,
  releaseVersion,
  crane,
  # Source of the `nix` flake input.
  nix-src,
  # Source of the `nix-eval-jobs` flake input.
  nix-eval-jobs-src,
  # The flake itself, which `hydra` wants unfiltered for its version stamp.
  rawSrc,
}:

rec {
  # FIXME: The Nix scopes are copied from `packageSetsFor` in the flake of
  # the Nix we pin. Since Nix 2.36 that is in Nix's `packaging/scopes.nix`;
  # take them from there once we track 2.36.
  packageSetsFor =
    pkgs:
    let
      splices = lib.mapCrossIndex packageSetsFor (lib.renameCrossIndexFrom "pkgs" pkgs);
      otherSplicesFor = name: lib.renameCrossIndexTo "self" (lib.mapCrossIndex (s: s.${name}) splices);

      # Layered directly on `pkgs`, unlike the scopes below.
      nixDependencies =
        lib.makeScopeWithSplicing'
          {
            inherit (pkgs) splicePackages newScope;
          }
          {
            otherSplices = otherSplicesFor "nixDependencies";
            f =
              scope:
              let
                super = import (nix-src + "/packaging/dependencies.nix") {
                  inherit pkgs;
                  inherit (pkgs) stdenv;
                  inputs = { };
                } scope;
              in
              super
              // {
                # `dependencies.nix` patches boost for
                # https://github.com/NixOS/nix/issues/16174, but the nixpkgs we
                # track already backports that commit (boostorg/context@5883212),
                # so cut the extra patches.
                #
                # FIXME avoid messing up in Nix itself instead.
                boost = super.boost.overrideAttrs (_: {
                  patches = pkgs.boost.patches;
                });
              };
          };

      nixComponents =
        lib.makeScopeWithSplicing'
          {
            inherit (pkgs) splicePackages;
            inherit (nixDependencies) newScope;
          }
          {
            otherSplices = otherSplicesFor "nixComponents";
            f = import (nix-src + "/packaging/components.nix") {
              officialRelease = true;
              inherit lib pkgs;
              src = nix-src;
              maintainers = [ ];
            };
          };

      # Also on Nix's dependencies, so things that link Nix agree on
      # libraries.
      hydraComponents =
        lib.makeScopeWithSplicing'
          {
            inherit (pkgs) splicePackages;
            inherit (nixDependencies) newScope;
          }
          {
            otherSplices = otherSplicesFor "hydraComponents";
            f = import ./components.nix {
              inherit
                version
                releaseVersion
                nixComponents
                nix-eval-jobs-src
                rawSrc
                ;
              craneLib = crane.mkLib pkgs;
            };
          };
    in
    # Some splices, like `pkgsTargetTarget`, are largely empty package sets
    # without `newScope` (or even `lib`, hence the `lib` argument above);
    # give empty scopes for those, as Nix does.
    lib.mapAttrs (_: v: if pkgs ? newScope then v else { }) {
      inherit nixDependencies nixComponents hydraComponents;
    };
}

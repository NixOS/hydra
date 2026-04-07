{
  pkgs,
  hydra,
  hydra-tests,
  hydra-manual,
  hydra-linters,
  hydra-queue-runner,
}:

let
  lib = pkgs.lib;

  components = [
    hydra
    hydra-tests
    hydra-manual
    hydra-linters
    hydra-queue-runner
  ];

  # Collect and deduplicate build inputs from all components,
  # filtering out the components themselves.
  internalDrvPaths = lib.listToAttrs (
    map (c: {
      name = builtins.unsafeDiscardStringContext c.drvPath;
      value = null;
    }) components
  );

  isInternal = dep: internalDrvPaths ? ${builtins.unsafeDiscardStringContext dep.drvPath or "_"};

  collectInputs =
    attr: lib.unique (lib.filter (x: !isInternal x) (lib.concatMap (c: c.${attr} or [ ]) components));
in

hydra.overrideAttrs (
  finalAttrs: prevAttrs: {
    pname = "shell-for-hydra";

    src = null;
    sourceRoot = null;

    nativeBuildInputs =
      collectInputs "nativeBuildInputs"
      ++ (with pkgs; [
        clippy
        nixfmt
        rustfmt
        taplo
      ]);
    buildInputs = collectInputs "buildInputs";

    inherit (hydra-tests) OPENLDAP_ROOT;

    # Better default for local development: build with debug info and
    # without optimizations. Foreman scripts also read this to pick the
    # right cargo target directory.
    mesonBuildType = "debug";

    # TODO: use factored-out Nix packaging infra to combine mesonFlags
    # from each component (transforming `-Dfoo=bar` to `-Dsubproject:foo=bar`)
    mesonFlags = [ ];

    RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
  }
)

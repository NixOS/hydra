{
  pkgs,
  hydra,
  hydra-tests,
  hydra-manual,
  hydra-linters,
  hydra-queue-runner,
  hydra-builder,
}:

let
  inherit (pkgs) lib;

  components = [
    hydra
    hydra-tests
    hydra-manual
    hydra-linters
    hydra-queue-runner
    hydra-builder
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
  _: _: {
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

    # TODO: use factored-out Nix packaging infra to combine mesonFlags
    # from each component (transforming `-Dfoo=bar` to `-Dsubproject:foo=bar`)
    mesonFlags = [ ];

    RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";
  }
)

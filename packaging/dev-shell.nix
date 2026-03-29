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

    # TODO: use factored-out Nix packaging infra to combine mesonFlags
    # from each component (transforming `-Dfoo=bar` to `-Dsubproject:foo=bar`)
    mesonFlags = [ ];

    RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";

    shellHook = ''
      pushd $(git rev-parse --show-toplevel) >/dev/null

      PATH=$(pwd)/build/subprojects/hydra/hydra-evaluator:$(pwd)/subprojects/hydra/script:$PATH
      PERL5LIB=$(pwd)/subprojects/hydra/lib:$PERL5LIB
      export HYDRA_HOME="$(pwd)/subprojects/hydra/"
      mkdir -p .hydra-data
      export HYDRA_DATA="$(pwd)/.hydra-data"
      export HYDRA_DBI='dbi:Pg:dbname=hydra;host=localhost;port=64444'

      popd >/dev/null
    '';
  }
)

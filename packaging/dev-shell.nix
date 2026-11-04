{
  pkgs,
  nix-perl,
  hydra-perl,
  hydra,
  hydra-notify,
  hydra-evaluator-helpers,
  hydra-tests,
  hydra-manual,
  hydra-linters,
  hydra-queue-runner,
  hydra-builder,
  hydra-ad-hoc,
  hydra-evaluator,
  hydra-cargo-deps,
  nix-eval-jobs,
}:

let
  inherit (pkgs) lib;

  hydraPrograms = pkgs.callPackage ./programs.nix {
    inherit (hydra-perl) nix;
    inherit nix-eval-jobs;
  };

  # What each program the test suite launches is given (see
  # `HydraTestPrograms`). Here every one of them runs unwrapped, the Perl
  # from the source tree, which the suite puts in place of `@scripts@`.
  envFor = hydraPrograms.envFor { localPath = name: "@scripts@/${name}"; };

  # What the tests' plugins and `RunCommand` hooks run.
  pluginPath = lib.makeBinPath [ pkgs.coreutils ];

  testProgramEnv = pkgs.writeText "hydra-test-program-env.json" (
    builtins.toJSON (
      lib.mapAttrs (
        _: entry:
        envFor entry
        // lib.optionalAttrs (entry ? path) { PATH = lib.makeBinPath entry.path; }
        // lib.optionalAttrs (entry.runsPlugins or false) { HYDRA_PLUGIN_PATH = pluginPath; }
      ) hydraPrograms.programs
      // {
        # The test process itself, which runs the web app and plugins
        # in-process, so needs what any of the Perl does.
        hydra-tests =
          lib.foldl' (env: script: env // envFor hydraPrograms.programs.${script}) { } (
            lib.concatMap (w: w.scripts) [
              hydra
              hydra-notify
              hydra-evaluator-helpers
            ]
          )
          // {
            HYDRA_PLUGIN_PATH = pluginPath;
          };
      }
    )
  );

  components = [
    nix-perl
    hydra-perl
    hydra
    hydra-notify
    hydra-evaluator-helpers
    hydra-tests
    hydra-manual
    hydra-linters
    hydra-queue-runner
    hydra-builder
    hydra-ad-hoc
    hydra-evaluator
    # The Rust crates are thin `runCommand`s that copy a binary out of the
    # shared workspace build, so they carry no build inputs of their own.
    # This is where cargo and rustc come from.
    hydra-cargo-deps
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

hydra-perl.overrideAttrs (
  _: _: {
    pname = "shell-for-hydra";

    src = null;
    sourceRoot = null;

    nativeBuildInputs = collectInputs "nativeBuildInputs" ++ [
      pkgs.foreman
      hydra-tests.KANIDM_ROOT
      pkgs.cargo-nextest
      pkgs.clippy
      pkgs.nixfmt
      pkgs.rustfmt
      pkgs.taplo
      pkgs.sqlx-cli
    ];
    buildInputs = collectInputs "buildInputs";

    inherit (hydra-tests) OPENLDAP_ROOT;

    HYDRA_TEST_PROGRAM_ENV = testProgramEnv;

    # Better default for local development: build with debug info and
    # without optimizations. Foreman scripts also read this to pick the
    # right cargo target directory.
    mesonBuildType = "debug";

    # TODO: use factored-out Nix packaging infra to combine mesonFlags
    # from each component (transforming `-Dfoo=bar` to `-Dsubproject:foo=bar`)
    mesonFlags = [ ];

    RUST_SRC_PATH = "${pkgs.rustPlatform.rustLibSrc}";

    shellHook = ''
      # Create .version for nix-perl meson subproject
      echo ${nix-perl.version} > subprojects/nix-perl/.version
    '';
  }
)

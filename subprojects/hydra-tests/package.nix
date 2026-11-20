{
  stdenv,
  lib,
  version,

  hydra-perl,
  hydra,
  hydra-notify,
  hydra-evaluator-helpers,
  hydra-queue-runner,
  hydra-builder,
  hydra-ad-hoc,
  hydra-submit-evaluation,
  hydra-process-evaluation,
  hydraPrograms,

  meson,
  ninja,
  socat,

  perl,
  perlPackages,
  nixComponents,

  bzip2,
  top-git,
  mercurial,
  darcs,
  git,
  subversion,
  breezy,
  openldap,
  postgresql_17,
  pixz,
  nix-eval-jobs,
  curl,
  kanidm_1_10,
  jq,

  cacert,
  glibcLocales,
  libressl,
  python3,
  coreutils,
  writeText,
}:

let
  # What each program the suite launches is given (see `HydraTestPrograms`).
  # The Perl here is wrapped, and its wrappers give it its programs, so all
  # that is left are the Rust programs, whose units would, and the plugin
  # path, which is the deployment's.
  wrappers = [
    hydra
    hydra-notify
    hydra-evaluator-helpers
  ];
  wrapperOf =
    name: lib.findFirst (w: lib.elem name w.scripts) (throw "no wrapper has `${name}`") wrappers;
  isWrapped = name: lib.any (w: lib.elem name w.scripts) wrappers;

  envFor = hydraPrograms.envFor { localPath = local: "${wrapperOf local}/bin/${local}"; };

  # What the tests' plugins and `RunCommand` hooks run.
  pluginPath = lib.makeBinPath [ coreutils ];

  programEnv = writeText "hydra-test-program-env.json" (
    builtins.toJSON (
      lib.mapAttrs (
        name: entry:
        lib.optionalAttrs (!isWrapped name) (
          envFor entry // lib.optionalAttrs (entry ? path) { PATH = lib.makeBinPath entry.path; }
        )
        // lib.optionalAttrs (entry.runsPlugins or false) { HYDRA_PLUGIN_PATH = pluginPath; }
      ) hydraPrograms.programs
      // {
        # The test process itself, which runs the web app and plugins
        # in-process, so needs what any of the Perl does.
        hydra-tests =
          lib.foldl' (env: script: env // envFor hydraPrograms.programs.${script}) { } (
            lib.concatMap (w: w.scripts) wrappers
          )
          // {
            HYDRA_PLUGIN_PATH = pluginPath;
          };
      }
    )
  );
in
stdenv.mkDerivation (finalAttrs: {
  pname = "hydra-tests";
  inherit version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../subprojects/hydra-tests
      ../../version.txt
    ];
  };

  sourceRoot = "${finalAttrs.src.name}/subprojects/hydra-tests";

  postPatch = ''
    patchShebangs .
  '';

  dontBuild = true;

  strictDeps = true;

  nativeBuildInputs = [
    meson
    ninja
    hydra
    hydra-notify
    hydra-evaluator-helpers
    hydra-queue-runner
    hydra-builder
    hydra-ad-hoc
    hydra-submit-evaluation
    hydra-process-evaluation
    perl
    nixComponents.nix-cli
    bzip2
    darcs
    git
    top-git
    mercurial
    subversion
    breezy
    openldap
    postgresql_17
    pixz
    nix-eval-jobs
    socat
    curl
    kanidm_1_10
    jq
  ]
  ++ hydra.perlDeps;

  buildInputs = [
    cacert
    glibcLocales
    libressl.nc
    python3
    nixComponents.nix-cli
    perl
  ]
  ++ hydra.perlDeps
  ++ (with perlPackages; [
    # Test-only Perl modules used by the OIDC end-to-end test
    HTTPCookieJar
    TestLongString
    TestWWWMechanize
    TestWWWMechanizeCatalyst
  ]);

  OPENLDAP_ROOT = openldap;
  KANIDM_ROOT = kanidm_1_10;
  # What each program the suite launches is given; see `HydraTestPrograms`.
  HYDRA_TEST_PROGRAM_ENV = programEnv;

  mesonBuildType = "release";
  mesonFlags = [
    "-Dhydra_home=${hydra-perl}/libexec/hydra"
  ];

  doCheck = true;

  mesonCheckFlags = [ "--interactive" ];

  preCheck = ''
    export LOGNAME=''${LOGNAME:-foo}
    export HOME=$(mktemp -d)
  '';

  installPhase = ''
    touch $out
  '';

  meta.description = "Tests for Hydra on ${stdenv.system}";
})

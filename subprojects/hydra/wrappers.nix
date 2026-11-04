# Runnable packages of Hydra's Perl scripts, built from the unwrapped
# `hydra-perl`. Each package wraps its own scripts with the tools they call,
# so that the web app doesn't carry every version control system, and the
# evaluator and notifier don't carry the web app.
{
  stdenv,
  lib,
  releaseVersion,

  hydra-perl,
  perlPackages,
  makeWrapper,

  nixComponents,
  nix-eval-jobs,

  coreutils,
  findutils,
  gnused,

  # Archive tools, for the web app's listings of build products and its log
  # and closure downloads.
  bzip2,
  gnutar,
  gzip,
  pixz,
  unzip,
  xz,
  rpm,
  dpkg,
  cdrkit,

  # For `CompressLog`, alongside `bzip2`.
  zstd,

  # Version control, for the input plugins.
  git,
  openssh,
  top-git,
  mercurial,
  subversion,
  darcs,
  breezy,
}:

let
  perlLib = "${hydra-perl}/libexec/hydra/lib:${perlPackages.makePerlPath [ hydra-perl.perlDeps ]}";

  webPath = [
    nixComponents.nix-cli
    coreutils
    findutils
    bzip2
    gnutar
    gzip
    pixz
    unzip
    xz
  ]
  ++ lib.optionals stdenv.hostPlatform.isLinux [
    rpm
    dpkg
    cdrkit
  ];

  # The scripts that run plugins get everything. Plugins may run what they
  # like, and `RunCommand` hooks inherit this `PATH`, so it stays as broad as
  # the one `PATH` all the scripts used to share.
  #
  # `hydra-server` loads the plugins too, but only asks the input plugins
  # for `supportedInputTypes`, which must not run anything, so it does
  # without these.
  pluginPath = webPath ++ [
    gnused
    zstd
    git
    openssh
    top-git
    mercurial
    subversion
    darcs
    breezy
  ];

  wrapScripts =
    {
      pname,
      description,
      scripts,
      path,
      extraWrapperArgs ? [ ],
    }:
    stdenv.mkDerivation {
      inherit pname;
      inherit (hydra-perl) version;

      dontUnpack = true;

      nativeBuildInputs = [ makeWrapper ];

      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
      ''
      + lib.concatMapStrings (script: ''
        makeWrapper ${hydra-perl}/libexec/hydra/script/${script} $out/bin/${script} \
          --prefix PERL5LIB : ${perlLib} \
          --prefix PATH : $out/bin:${lib.makeBinPath path} \
          --set HYDRA_HOME ${hydra-perl}/libexec/hydra \
          ${lib.escapeShellArgs extraWrapperArgs}
      '') scripts
      + ''
        runHook postInstall
      '';

      meta.description = "${description} on ${stdenv.system}";
      passthru = {
        inherit (hydra-perl) perlDeps nix;
      };
    };

  hydraScripts = [
    "hydra-backfill-ids"
    "hydra-create-user"
    "hydra-init"
    "hydra-s3-backup-collect-garbage"
    "hydra-send-stats"
    "hydra-server"
    "hydra-update-gc-roots"
  ];

  notifyScripts = [
    "hydra-notify"
  ];

  evaluatorHelperScripts = [
    "hydra-eval-jobset"
    "hydra-fetch-input"
    "hydra-prepare-declarative-jobset"
    "nix-prefetch-bzr"
    "nix-prefetch-git"
    "nix-prefetch-hg"
  ];

  # Meson doesn't install `hydra-dev-server`. Every other script must be in
  # exactly one of the lists above, or it would silently go unwrapped.
  allScripts = lib.remove "hydra-dev-server" (lib.attrNames (builtins.readDir ./script));
in

assert lib.assertMsg (
  lib.sort lib.lessThan (hydraScripts ++ notifyScripts ++ evaluatorHelperScripts)
  == lib.sort lib.lessThan allScripts
) "subprojects/hydra/wrappers.nix: every script must be wrapped by exactly one package";

{
  hydra = wrapScripts {
    pname = "hydra";
    description = "Hydra's web app and admin tools";
    scripts = hydraScripts;
    path = webPath;
    # Shown in the web app's footer.
    extraWrapperArgs = [
      "--set"
      "HYDRA_RELEASE"
      releaseVersion
      "--set"
      "NIX_RELEASE"
      (nixComponents.nix-cli.name or "unknown")
      "--set"
      "NIX_EVAL_JOBS_RELEASE"
      (nix-eval-jobs.name or "unknown")
    ];
  };

  hydra-notify = wrapScripts {
    pname = "hydra-notify";
    description = "Hydra's notifier";
    scripts = notifyScripts;
    path = pluginPath;
  };

  # The Perl that `hydra-evaluator` runs to evaluate a jobset, which fetches
  # the inputs with the input plugins and runs `nix-eval-jobs`.
  hydra-evaluator-helpers = wrapScripts {
    pname = "hydra-evaluator-helpers";
    description = "Hydra's jobset evaluation for hydra-evaluator";
    scripts = evaluatorHelperScripts;
    path = pluginPath ++ [ nix-eval-jobs ];
  };
}

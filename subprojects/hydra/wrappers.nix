# Runnable packages of Hydra's Perl scripts, built from the unwrapped
# `hydra-perl`. Each script is wrapped with the programs it runs, which
# `hydraPrograms` (`packaging/programs.nix`) says, so that the web app
# carries only the version control tools it uses, and the evaluator and
# notifier don't carry the web app.
{
  stdenv,
  lib,
  releaseVersion,

  hydra-perl,
  perl,
  makeWrapper,

  nixComponents,
  nix-eval-jobs,

  hydraPrograms,
}:

let
  # One directory for all the Perl Hydra uses, with what it needs in turn.
  perlEnv = perl.withPackages (_: hydra-perl.perlDeps);
  perlLib = "${hydra-perl}/libexec/hydra/lib:${perlEnv}/${perl.libPrefix}";

  wrapScripts =
    {
      pname,
      description,
      scripts,
      extraWrapperArgs ? [ ],
    }:
    let
      # A script's own programs are wrapped by this same package.
      localPath =
        name:
        assert lib.assertMsg (lib.elem name scripts) "${pname}: `${name}' is not one of its scripts";
        "${placeholder "out"}/bin/${name}";

      envOf = script: hydraPrograms.envFor { inherit localPath; } hydraPrograms.programs.${script};

      wrapCommand =
        script:
        [
          "makeWrapper"
          "${hydra-perl}/libexec/hydra/script/${script}"
          "${placeholder "out"}/bin/${script}"
          "--prefix"
          "PERL5LIB"
          ":"
          perlLib
          "--set"
          "HYDRA_HOME"
          "${hydra-perl}/libexec/hydra"
        ]
        ++ lib.concatLists (
          lib.mapAttrsToList (name: value: [
            "--set"
            name
            value
          ]) (envOf script)
        )
        ++ extraWrapperArgs;
    in
    stdenv.mkDerivation {
      inherit pname;
      inherit (hydra-perl) version;

      dontUnpack = true;

      strictDeps = true;

      nativeBuildInputs = [ makeWrapper ];

      installPhase = ''
        runHook preInstall
        mkdir -p $out/bin
      ''
      + lib.concatMapStrings (script: lib.escapeShellArgs (wrapCommand script) + "\n") scripts
      + ''
        runHook postInstall
      '';

      meta.description = "${description} on ${stdenv.system}";
      passthru = {
        inherit (hydra-perl) perlDeps nix;
        # Perl with everything Hydra's Perl uses, for running Perl against it.
        inherit perlEnv;
        inherit scripts;
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
  };

  # The Perl that `hydra-submit-evaluation` runs to submit an evaluation,
  # which fetches the inputs with the input plugins.
  hydra-evaluator-helpers = wrapScripts {
    pname = "hydra-evaluator-helpers";
    description = "Hydra's input fetching for hydra-submit-evaluation";
    scripts = evaluatorHelperScripts;
  };
}

{
  config,
  pkgs,
  lib,
  ...
}:

with lib;

let
  cfg = config.services.hydra-evaluator-dev;

  # See hydra-evaluator-dev's enable option's description for why we need this.
  # Tl;dr, the hope is that longer term we will stop needing this.
  webCfg = config.services.hydra-dev;

  inherit
    (import ./web-app-env.nix {
      inherit lib pkgs;
      cfg = webCfg;
    })
    baseDir
    env
    dbUrlWithAppName
    ;

  format = pkgs.formats.toml { };

  # What the evaluator runs, with the Nix this machine uses.
  hydraPrograms = pkgs.callPackage ../packaging/programs.nix {
    nix = config.nix.package;
    nix-eval-jobs = cfg.nixEvalJobsPackage;
  };
  programs = hydraPrograms.programs.hydra-submit-evaluation;
in

{
  imports = [
    (mkRenamedOptionModule
      [ "services" "hydra-dev" "evaluatorSettings" ]
      [ "services" "hydra-evaluator-dev" "settings" ]
    )
    (mkRenamedOptionModule
      [ "services" "hydra-dev" "minimumDiskFreeEvaluator" ]
      [ "services" "hydra-evaluator-dev" "minimumDiskFree" ]
    )
    (mkRemovedOptionModule
      [
        "services"
        "hydra-dev"
        "evaluatorExecutable"
      ]
      "Set `services.hydra-evaluator-dev.submitEvaluationPackage` and `processEvaluationPackage` instead."
    )
    (mkRemovedOptionModule
      [
        "services"
        "hydra-evaluator-dev"
        "package"
      ]
      "Set `services.hydra-evaluator-dev.submitEvaluationPackage` and `processEvaluationPackage` instead."
    )
  ];

  options = {
    services.hydra-evaluator-dev = {
      enable = mkOption {
        type = types.bool;
        default = webCfg.enable;
        defaultText = literalExpression "config.services.hydra-dev.enable";
        description = ''
          Whether to run the evaluator.

          Until more work is done, it must run on the same machine as the
          web app (`services.hydra-dev`). It runs Hydra's Perl, which reads
          the web app's `hydra.conf` and data directory, and it evaluates
          into the local Nix store, which the queue runner and web app also
          read from.
        '';
      };

      submitEvaluationPackage = mkOption {
        type = types.package;
        default = pkgs.hydraComponents.hydra-submit-evaluation;
        defaultText = literalExpression "pkgs.hydraComponents.hydra-submit-evaluation";
        description = "The `hydra-submit-evaluation` package.";
      };

      processEvaluationPackage = mkOption {
        type = types.package;
        default = pkgs.hydraComponents.hydra-process-evaluation;
        defaultText = literalExpression "pkgs.hydraComponents.hydra-process-evaluation";
        description = "The `hydra-process-evaluation` package.";
      };

      helpersPackage = mkOption {
        type = types.package;
        default = pkgs.hydraComponents.hydra-evaluator-helpers;
        defaultText = literalExpression "pkgs.hydraComponents.hydra-evaluator-helpers";
        description = ''
          The package providing `hydra-fetch-input` and `hydra-prepare-declarative-jobset`,
          which the evaluator runs.
        '';
      };

      nixEvalJobsPackage = mkOption {
        type = types.package;
        default = pkgs.hydraComponents.nix-eval-jobs;
        defaultText = literalExpression "pkgs.hydraComponents.nix-eval-jobs";
        description = "The `nix-eval-jobs` package the evaluator runs.";
      };

      settings = mkOption {
        type = types.submodule {
          freeformType = format.type;
          options = {
            allow_import_from_derivation = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Whether jobsets may import from derivations.
                Off unless asked for, because it lets an evaluation demand builds.
              '';
            };
            allow_unrestricted_eval = mkOption {
              type = types.bool;
              default = false;
              description = ''
                Whether non-flake jobsets are evaluated without `restrict-eval`.
                Off unless asked for, because it lets an evaluation read any path and URL.
              '';
            };
            evaluator_workers = mkOption {
              type = types.ints.positive;
              default = 1;
              description = "How many `nix-eval-jobs` workers to run.";
            };
            evaluator_max_memory_size = mkOption {
              type = types.ints.positive;
              default = 4096;
              description = "The memory each worker may use, in MiB, before it is restarted.";
            };
            evaluator_max_jobs = mkOption {
              type = types.ints.unsigned;
              default = 1;
              description = "How many builds an evaluation may run locally, e.g. for import-from-derivation. 0 forbids local builds.";
            };
            eval_timeout = mkOption {
              type = types.ints.positive;
              default = 3600;
              description = "How many seconds an evaluation may run. It is the evaluation build's timeout, so the build is killed and the evaluation fails.";
            };
            roots_dir = mkOption {
              type = types.path;
              default = webCfg.gcRootsDir;
              defaultText = literalExpression "config.services.hydra-dev.gcRootsDir";
              description = ''
                Where to root the evaluated derivations.
                It must be the directory `hydra-update-gc-roots` tidies.
              '';
            };
          };
        };
        default = { };
        description = ''
          Settings for `hydra-submit-evaluation` and `hydra-process-evaluation`, written to `/etc/hydra/evaluator.toml`.

          Every service in Rust in hydra has its own separate TOML configuration file,
          with just the settings it needs.
        '';
      };

      minimumDiskFree = mkOption {
        type = types.int;
        default = 0;
        description = ''
          Threshold of minimum disk space (GiB) to determine if the evaluator should run or not.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = webCfg.enable;
        message = "`services.hydra-evaluator-dev` needs `services.hydra-dev` on the same machine, for now.";
      }
    ];

    environment.etc."hydra/evaluator.toml".source = format.generate "evaluator.toml" cfg.settings;

    systemd.services.hydra-submit-evaluation = {
      # Hydra names every program it runs by its own variable, never by
      # `PATH`; see the `hydra-programs` crate.
      enableDefaultPath = false;
      wantedBy = [ "multi-user.target" ];
      requires = [ "hydra-init.service" ];
      # Not `hydra.conf`: only the Perl the evaluator runs reads it, and
      # that starts afresh for each evaluation.
      restartTriggers = [ config.environment.etc."hydra/evaluator.toml".source ];
      after = [
        "hydra-init.service"
        "network.target"
      ];
      # Not for anything Hydra runs, but for what Nix runs; see
      # `packaging/programs.nix`.
      path = programs.path;
      environment =
        env
        // hydraPrograms.envFor {
          # The Perl that has to stay so: input types are a plugin interface.
          localPath = name: "${cfg.helpersPackage}/bin/${name}";
        } programs
        // {
          HYDRA_DATABASE_URL = dbUrlWithAppName "hydra-submit-evaluation";
          # What plugins from outside Hydra run.
          HYDRA_PLUGIN_PATH = lib.makeBinPath webCfg.pluginPath;
        };
      serviceConfig = {
        ExecStart = escapeShellArgs [
          "@${cfg.submitEvaluationPackage}/bin/hydra-submit-evaluation"
          "hydra-submit-evaluation"
          "--config-path"
          "/etc/hydra/evaluator.toml"
        ];
        User = "hydra";
        Restart = "always";
        WorkingDirectory = baseDir;
      };
    };

    # The other half of evaluating: reads finished evaluation builds back
    # and turns them into the builds they found. Driven by `build_finished`,
    # with a catch-up pass at startup. It reads `evaluator.toml` only for
    # where to root the evaluated derivations.
    systemd.services.hydra-process-evaluation = {
      # It runs no programs at all.
      enableDefaultPath = false;
      wantedBy = [ "multi-user.target" ];
      requires = [ "hydra-init.service" ];
      restartTriggers = [ config.environment.etc."hydra/evaluator.toml".source ];
      after = [ "hydra-init.service" ];
      environment = env // {
        HYDRA_DATABASE_URL = dbUrlWithAppName "hydra-process-evaluation";
      };
      serviceConfig = {
        ExecStart = escapeShellArgs [
          "@${cfg.processEvaluationPackage}/bin/hydra-process-evaluation"
          "hydra-process-evaluation"
          "--config-path"
          "/etc/hydra/evaluator.toml"
        ];
        User = "hydra";
        Restart = "always";
        RestartSec = 5;
        WorkingDirectory = baseDir;
      };
    };

    # If there is less than a certain amount of free disk space, stop
    # the evaluator to prevent builds from failing or aborting.
    # Leaves a tag file indicating this reason; if the tag file exists
    # and disk space is above the threshold + 10GB, the evaluator will be
    # restarted; starting it if it is already started is not harmful.
    systemd.services.hydra-submit-evaluation-check-space = {
      script = ''
        ${builtins.readFile ./check-space.sh}
        spacestopstart hydra-submit-evaluation ${toString cfg.minimumDiskFree}
      '';
      startAt = "*:0/5";
    };
  };
}

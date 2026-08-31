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
      inherit lib;
      cfg = webCfg;
    })
    baseDir
    env
    dbUrlWithAppName
    ;

  format = pkgs.formats.toml { };
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
    (mkRemovedOptionModule [
      "services"
      "hydra-dev"
      "evaluatorExecutable"
    ] "Set `services.hydra-evaluator-dev.package` to the `hydra-evaluator` package instead.")
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

      package = mkOption {
        type = types.package;
        description = "The `hydra-evaluator` package.";
      };

      nixEvalJobsPackage = mkOption {
        type = types.package;
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
            max_concurrent_evals = mkOption {
              type = types.ints.positive;
              default = 4;
              description = "How many jobsets to evaluate at once.";
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
          Settings for `hydra-evaluator`, written to `/etc/hydra/evaluator.toml`.

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

    systemd.services.hydra-evaluator = {
      wantedBy = [ "multi-user.target" ];
      requires = [ "hydra-init.service" ];
      # Not `hydra.conf`: only the Perl the evaluator runs reads it, and
      # that starts afresh for each evaluation.
      restartTriggers = [ config.environment.etc."hydra/evaluator.toml".source ];
      after = [
        "hydra-init.service"
        "network.target"
      ];
      path = with pkgs; [
        hostname-debian
        # Because hydra-evaluator calls `hydra-fetch-input`, which is Perl
        # and must stay so: input types are a plugin interface.
        webCfg.package
        config.nix.package
        cfg.nixEvalJobsPackage
      ];
      environment = env // {
        HYDRA_DATABASE_URL = dbUrlWithAppName "hydra-evaluator";
      };
      serviceConfig = {
        ExecStart = escapeShellArgs [
          "@${cfg.package}/bin/hydra-evaluator"
          "hydra-evaluator"
          "--config-path"
          "/etc/hydra/evaluator.toml"
        ];
        # `--unlock` goes through the same argument parsing, so it needs the
        # path too.
        ExecStopPost = escapeShellArgs [
          "${cfg.package}/bin/hydra-evaluator"
          "--config-path"
          "/etc/hydra/evaluator.toml"
          "--unlock"
        ];
        User = "hydra";
        Restart = "always";
        WorkingDirectory = baseDir;
      };
    };

    # If there is less than a certain amount of free disk space, stop
    # the evaluator to prevent builds from failing or aborting.
    # Leaves a tag file indicating this reason; if the tag file exists
    # and disk space is above the threshold + 10GB, the evaluator will be
    # restarted; starting it if it is already started is not harmful.
    systemd.services.hydra-evaluator-check-space = {
      script = ''
        ${builtins.readFile ./check-space.sh}
        spacestopstart hydra-evaluator ${toString cfg.minimumDiskFree}
      '';
      startAt = "*:0/5";
    };
  };
}

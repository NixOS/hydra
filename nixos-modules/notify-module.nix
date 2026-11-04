{
  config,
  pkgs,
  lib,
  ...
}:

with lib;

let
  cfg = config.services.hydra-notify-dev;

  # See hydra-notify-dev's enable option's description for why we need this.
  webCfg = config.services.hydra-dev;

  inherit
    (import ./web-app-env.nix {
      inherit lib pkgs;
      cfg = webCfg;
    })
    baseDir
    hydraConf
    dbUrlWithAppName
    env
    ;
in

{
  options = {
    services.hydra-notify-dev = {
      enable = mkOption {
        type = types.bool;
        default = webCfg.enable;
        defaultText = literalExpression "config.services.hydra-dev.enable";
        description = ''
          Whether to run `hydra-notify`, which runs the notification plugins.

          It must run on the same machine as the web app (`services.hydra-dev`).
          It reads the web app's `hydra.conf` and data directory, and its log
          compression rewrites the queue runner's build logs.
        '';
      };

      package = mkOption {
        type = types.package;
        description = "The `hydra-notify` package.";
      };
    };
  };

  config = mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${baseDir}/notify 0700 hydra-queue-runner hydra"
    ];

    systemd.services.hydra-notify = {
      wantedBy = [ "multi-user.target" ];
      requires = [ "hydra-init.service" ];
      after = [ "hydra-init.service" ];
      restartTriggers = [ hydraConf ];
      environment = env // {
        PGPASSFILE = "${baseDir}/pgpass-notify";
        HYDRA_DATABASE_URL = dbUrlWithAppName "hydra-notify";
      };
      serviceConfig = {
        ExecStart = escapeShellArgs [
          "@${cfg.package}/bin/hydra-notify"
          "hydra-notify"
        ];
        # FIXME: hydra-notify should not need to write to build-logs.
        # Move log compression into the queue-runner, then give
        # hydra-notify its own user again.
        User = "hydra-queue-runner";
        Restart = "always";
        RestartSec = 5;
      };
    };

    # Periodically compress build logs. The queue runner compresses
    # logs automatically after a step finishes, but this doesn't work
    # if the queue runner is stopped prematurely.
    systemd.services.hydra-compress-logs = {
      path = [
        pkgs.bzip2
        pkgs.zstd
      ];
      script = ''
        set -eou pipefail
        compression=$(sed -nr 's/compress_build_logs_compression = ()/\1/p' ${baseDir}/hydra.conf)
        if [[ $compression == "" || $compression == bzip2 ]]; then
          compressionCmd=(bzip2)
        elif [[ $compression == zstd ]]; then
          compressionCmd=(zstd --rm)
        fi
        find ${baseDir}/build-logs -ignore_readdir_race -type f -name "*.drv" -mtime +3 -size +0c -print0 | xargs -0 -r "''${compressionCmd[@]}" --force --quiet
      '';
      startAt = "Sun 01:45";
    };
  };
}

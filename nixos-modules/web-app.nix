{
  config,
  pkgs,
  lib ? pkgs.lib,
  ...
}:

with lib;

let

  cfg = config.services.hydra-dev;

  baseDir = "/var/lib/hydra";

  hydraConf = pkgs.writeScript "hydra.conf" cfg.extraConfig;

  hydraEnv = {
    HYDRA_DBI = cfg.dbi;
    HYDRA_CONFIG = "${baseDir}/hydra.conf";
    HYDRA_DATA = "${baseDir}";
  };

  env = {
    NIX_REMOTE = "daemon";
    PGPASSFILE = "${baseDir}/pgpass";
    NIX_REMOTE_SYSTEMS = concatStringsSep ":" cfg.buildMachinesFiles;
  }
  // optionalAttrs (cfg.smtpHost != null) {
    EMAIL_SENDER_TRANSPORT = "SMTP";
    EMAIL_SENDER_TRANSPORT_host = cfg.smtpHost;
  }
  // hydraEnv
  // cfg.extraEnv;

  serverEnv =
    env
    // {
      COLUMNS = "80";
      PGPASSFILE = "${baseDir}/pgpass-www"; # grrr
      XDG_CACHE_HOME = "${baseDir}/www/.cache";
    }
    // (optionalAttrs cfg.debugServer { DBIC_TRACE = "1"; });

  localDB = "dbi:Pg:dbname=hydra;user=hydra;";

  haveLocalDB = cfg.dbi == localDB;

in

{
  imports = [ ./postgresql.nix ];
  ###### interface
  options = {

    services.hydra-dev = rec {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to run Hydra services.
        '';
      };

      dbi = mkOption {
        type = types.str;
        default = localDB;
        example = "dbi:Pg:dbname=hydra;host=postgres.example.org;user=foo;";
        description = ''
          The DBI string for Hydra database connection.

          NOTE: Attempts to set `application_name` will be overridden by
          `hydra-TYPE` (where TYPE is e.g. `evaluator`, `queue-runner`,
          etc.) in all hydra services to more easily distinguish where
          queries are coming from.
        '';
      };

      package = mkOption {
        type = types.path;
        description = "The Hydra package.";
      };

      hydraURL = mkOption {
        type = types.str;
        description = ''
          The base URL for the Hydra webserver instance. Used for links in emails.
        '';
      };

      listenHost = mkOption {
        type = types.str;
        default = "*";
        example = "localhost";
        description = ''
          The hostname or address to listen on or <literal>*</literal> to listen
          on all interfaces.
        '';
      };

      port = mkOption {
        type = types.int;
        default = 3000;
        description = ''
          TCP port the web server should listen to.
        '';
      };

      minimumDiskFreeEvaluator = mkOption {
        type = types.int;
        default = 0;
        description = ''
          Threshold of minimum disk space (GiB) to determine if the evaluator should run or not.
        '';
      };

      notificationSender = mkOption {
        type = types.str;
        description = ''
          Sender email address used for email notifications.
        '';
      };

      smtpHost = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = [ "localhost" ];
        description = ''
          Hostname of the SMTP server to use to send email.
        '';
      };

      tracker = mkOption {
        type = types.str;
        default = "";
        description = ''
          Piece of HTML that is included on all pages.
        '';
      };

      logo = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to a file containing the logo of your Hydra instance.
        '';
      };

      debugServer = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to run the server in debug mode.";
      };

      extraConfig = mkOption {
        type = types.lines;
        description = "Extra lines for the Hydra configuration.";
      };

      extraEnv = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = "Extra environment variables for Hydra.";
      };

      gcRootsDir = mkOption {
        type = types.path;
        default = "/nix/var/nix/gcroots/hydra";
        description = "Directory that holds Hydra garbage collector roots.";
      };

      buildMachinesFiles = mkOption {
        type = types.listOf types.path;
        default = optional (config.nix.buildMachines != [ ]) "/etc/nix/machines";
        defaultText = literalExpression ''optional (config.nix.buildMachines != []) "/etc/nix/machines"'';
        example = [
          "/etc/nix/machines"
          "/var/lib/hydra/provisioner/machines"
        ];
        description = "List of files containing build machines.";
      };

      useSubstitutes = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to use binary caches for downloading store paths. Note that
          binary substitutions trigger (a potentially large number of) additional
          HTTP requests that slow down the queue monitor thread significantly.
          Also, this Hydra instance will serve those downloaded store paths to
          its users with its own signature attached as if it had built them
          itself, so don't enable this feature unless your active binary caches
          are absolute trustworthy.
        '';
      };
    };

  };

  ###### implementation

  config = mkIf cfg.enable {

    systemd.tmpfiles.rules = [
      "d ${baseDir} 0750 hydra hydra"
      "d ${baseDir}/www 0700 hydra-www hydra"
      "d ${baseDir}/notify 0700 hydra-queue-runner hydra"
      "d ${baseDir}/runcommand-logs 0750 hydra hydra"
      "L+ ${baseDir}/hydra.conf - - - - ${hydraConf}"
    ];

    users.users.hydra-www = {
      description = "Hydra web server";
      group = "hydra";
      isSystemUser = true;
      useDefaultShell = true;
      home = "${baseDir}/www";
    };

    services.postgresql.identMap = optionalString haveLocalDB ''
      hydra-users hydra-www hydra
    '';

    services.hydra-dev.extraConfig = ''
      using_frontend_proxy = 1
      base_uri = ${cfg.hydraURL}
      notification_sender = ${cfg.notificationSender}
      max_servers = 25
      compress_num_threads = 0
      ${optionalString (cfg.logo != null) ''
        hydra_logo = ${cfg.logo}
      ''}
      gc_roots_dir = ${cfg.gcRootsDir}
      use-substitutes = ${if cfg.useSubstitutes then "1" else "0"}

      ${optionalString (cfg.tracker != null) (
        let
          indentedTrackerData = lib.concatMapStringsSep "\n" (line: "    ${line}") (
            lib.splitString "\n" cfg.tracker
          );
        in
        ''
          tracker = <<TRACKER
          ${indentedTrackerData}
            TRACKER
        ''
      )}
    '';

    environment.systemPackages = [ cfg.package ];

    environment.variables = hydraEnv;

    systemd.services.hydra-server = {
      wantedBy = [ "multi-user.target" ];
      requires = [ "hydra-init.service" ];
      after = [ "hydra-init.service" ];
      environment = serverEnv // {
        HYDRA_DBI = "${serverEnv.HYDRA_DBI};application_name=hydra-server";
      };
      restartTriggers = [ hydraConf ];
      serviceConfig = {
        ExecStart = escapeShellArgs (
          [
            "@${cfg.package}/bin/hydra-server"
            "hydra-server"
            "-f"
            "-h"
            cfg.listenHost
            "-p"
            (toString cfg.port)
            "--max_spare_servers"
            "5"
            "--max_servers"
            "25"
            "--max_requests"
            "100"
          ]
          ++ optionals cfg.debugServer [ "-d" ]
        );
        User = "hydra-www";
        PermissionsStartOnly = true;
        Restart = "always";
      };
    };

    systemd.services.hydra-evaluator = {
      wantedBy = [ "multi-user.target" ];
      requires = [ "hydra-init.service" ];
      restartTriggers = [ hydraConf ];
      after = [
        "hydra-init.service"
        "network.target"
      ];
      path = with pkgs; [
        hostname-debian
        cfg.package
      ];
      environment = env // {
        HYDRA_DBI = "${env.HYDRA_DBI};application_name=hydra-evaluator";
      };
      serviceConfig = {
        ExecStart = escapeShellArgs [
          "@${cfg.package}/bin/hydra-evaluator"
          "hydra-evaluator"
        ];
        ExecStopPost = escapeShellArgs [
          "${cfg.package}/bin/hydra-evaluator"
          "--unlock"
        ];
        User = "hydra";
        Restart = "always";
        WorkingDirectory = baseDir;
      };
    };

    systemd.services.hydra-update-gc-roots = {
      requires = [ "hydra-init.service" ];
      after = [ "hydra-init.service" ];
      environment = env // {
        HYDRA_DBI = "${env.HYDRA_DBI};application_name=hydra-update-gc-roots";
      };
      serviceConfig = {
        ExecStart = escapeShellArgs [
          "@${cfg.package}/bin/hydra-update-gc-roots"
          "hydra-update-gc-roots"
        ];
        User = "hydra";
      };
      startAt = "2,14:15";
    };

    systemd.services.hydra-send-stats = {
      wantedBy = [ "multi-user.target" ];
      after = [ "hydra-init.service" ];
      environment = env // {
        HYDRA_DBI = "${env.HYDRA_DBI};application_name=hydra-send-stats";
      };
      serviceConfig = {
        ExecStart = escapeShellArgs [
          "@${cfg.package}/bin/hydra-send-stats"
          "hydra-send-stats"
        ];
        User = "hydra";
      };
    };

    systemd.services.hydra-notify = {
      wantedBy = [ "multi-user.target" ];
      requires = [ "hydra-init.service" ];
      after = [ "hydra-init.service" ];
      restartTriggers = [ hydraConf ];
      path = [ pkgs.zstd ];
      environment = env // {
        PGPASSFILE = "${baseDir}/pgpass-notify";
        HYDRA_DBI = "${env.HYDRA_DBI};application_name=hydra-notify";
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

    # If there is less than a certain amount of free disk space, stop
    # the evaluator to prevent builds from failing or aborting.
    # Leaves a tag file indicating this reason; if the tag file exists
    # and disk space is above the threshold + 10GB, the evaluator will be
    # restarted; starting it if it is already started is not harmful.
    systemd.services.hydra-evaluator-check-space = {
      script = ''
        ${builtins.readFile ./check-space.sh}
        spacestopstart hydra-evaluator ${toString cfg.minimumDiskFreeEvaluator}
      '';
      startAt = "*:0/5";
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

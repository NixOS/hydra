{ config, pkgs, lib ? pkgs.lib, ... }:

with lib;

let

  cfg = config.services.hydra-dev;

  baseDir = "/var/lib/hydra";

  hydraConf = pkgs.writeScript "hydra.conf" cfg.extraConfig;

  hydraEnv =
    { HYDRA_DBI = cfg.dbi;
      HYDRA_CONFIG = "${baseDir}/hydra.conf";
      HYDRA_DATA = "${baseDir}";
    };

  env =
    { NIX_REMOTE = "daemon";
      PGPASSFILE = "${baseDir}/pgpass";
      NIX_REMOTE_SYSTEMS = concatStringsSep ":" cfg.buildMachinesFiles;
    } // optionalAttrs (cfg.smtpHost != null) {
      EMAIL_SENDER_TRANSPORT = "SMTP";
      EMAIL_SENDER_TRANSPORT_host = cfg.smtpHost;
    } // hydraEnv // cfg.extraEnv;

  serverEnv = env //
    {
      COLUMNS = "80";
      PGPASSFILE = "${baseDir}/pgpass-www"; # grrr
      XDG_CACHE_HOME = "${baseDir}/www/.cache";
    } // (optionalAttrs cfg.debugServer { DBIC_TRACE = "1"; });

  localDB = "dbi:Pg:dbname=hydra;user=hydra;";

  haveLocalDB = cfg.dbi == localDB;

in

{
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

      minimumDiskFree = mkOption {
        type = types.int;
        default = 0;
        description = ''
          Threshold of minimum disk space (GiB) to determine if the queue runner should run or not.
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
        example = ["localhost"];
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
        default = {};
        description = "Extra environment variables for Hydra.";
      };

      gcRootsDir = mkOption {
        type = types.path;
        default = "/nix/var/nix/gcroots/hydra";
        description = "Directory that holds Hydra garbage collector roots.";
      };

      buildMachinesFiles = mkOption {
        type = types.listOf types.path;
        default = optional (config.nix.buildMachines != []) "/etc/nix/machines";
        defaultText = literalExpression ''optional (config.nix.buildMachines != []) "/etc/nix/machines"'';
        example = [ "/etc/nix/machines" "/var/lib/hydra/provisioner/machines" ];
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
    ];

    users.extraGroups.hydra = { };

    users.extraUsers.hydra =
      { description = "Hydra";
        group = "hydra";
        home = baseDir;
        isSystemUser = true;
        useDefaultShell = true;
      };

    users.extraUsers.hydra-queue-runner =
      { description = "Hydra queue runner";
        group = "hydra";
        useDefaultShell = true;
        isSystemUser = true;
        home = "${baseDir}/queue-runner"; # really only to keep SSH happy
      };

    users.extraUsers.hydra-www =
      { description = "Hydra web server";
        group = "hydra";
        isSystemUser = true;
        useDefaultShell = true;
      };

    nix.settings = {
      trusted-users = [ "hydra-queue-runner" ];
      keep-outputs = true;
      keep-derivations = true;
    };

    services.hydra-dev.extraConfig =
      ''
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

        ${optionalString (cfg.tracker != null) (let
            indentedTrackerData = lib.concatMapStringsSep "\n" (line: "    ${line}") (lib.splitString "\n" cfg.tracker);
          in ''
          tracker = <<TRACKER
          ${indentedTrackerData}
            TRACKER
        '')}
      '';

    environment.systemPackages = [ cfg.package ];

    environment.variables = hydraEnv;

    systemd.services.hydra-init =
      { wantedBy = [ "multi-user.target" ];
        requires = optional haveLocalDB "postgresql.service";
        after = optional haveLocalDB "postgresql.service";
        environment = env // {
          HYDRA_DBI = "${env.HYDRA_DBI};application_name=hydra-init";
        };
        path = [ pkgs.util-linux ];
        preStart = ''
          ln -sf ${hydraConf} ${baseDir}/hydra.conf

          mkdir -m 0700 -p ${baseDir}/www
          chown hydra-www:hydra ${baseDir}/www

          mkdir -m 0700 -p ${baseDir}/queue-runner
          mkdir -m 0750 -p ${baseDir}/build-logs
          mkdir -m 0750 -p ${baseDir}/runcommand-logs
          chown hydra-queue-runner:hydra \
            ${baseDir}/queue-runner \
            ${baseDir}/build-logs \
            ${baseDir}/runcommand-logs

          ${optionalString haveLocalDB ''
            if ! [ -e ${baseDir}/.db-created ]; then
              runuser -u ${config.services.postgresql.superUser} -- ${config.services.postgresql.package}/bin/createuser hydra
              runuser -u ${config.services.postgresql.superUser} -- ${config.services.postgresql.package}/bin/createdb -O hydra hydra
              touch ${baseDir}/.db-created
            fi
            echo "create extension if not exists pg_trgm" | runuser -u ${config.services.postgresql.superUser} -- ${config.services.postgresql.package}/bin/psql hydra
          ''}

          if [ ! -e ${cfg.gcRootsDir} ]; then

            # Move legacy roots directory.
            if [ -e /nix/var/nix/gcroots/per-user/hydra/hydra-roots ]; then
              mv /nix/var/nix/gcroots/per-user/hydra/hydra-roots ${cfg.gcRootsDir}
            fi

            mkdir -p ${cfg.gcRootsDir}
          fi

          # Move legacy hydra-www roots.
          if [ -e /nix/var/nix/gcroots/per-user/hydra-www/hydra-roots ]; then
            find /nix/var/nix/gcroots/per-user/hydra-www/hydra-roots/ -type f \
              | xargs -r mv -f -t ${cfg.gcRootsDir}/
            rmdir /nix/var/nix/gcroots/per-user/hydra-www/hydra-roots
          fi

          chown hydra:hydra ${cfg.gcRootsDir}
          chmod 2775 ${cfg.gcRootsDir}
        '';
        serviceConfig.ExecStart = "${cfg.package}/bin/hydra-init";
        serviceConfig.PermissionsStartOnly = true;
        serviceConfig.User = "hydra";
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
      };

    systemd.services.hydra-server =
      { wantedBy = [ "multi-user.target" ];
        requires = [ "hydra-init.service" ];
        after = [ "hydra-init.service" ];
        environment = serverEnv // {
          HYDRA_DBI = "${serverEnv.HYDRA_DBI};application_name=hydra-server";
        };
        restartTriggers = [ hydraConf ];
        serviceConfig =
          { ExecStart =
              "@${cfg.package}/bin/hydra-server hydra-server -f -h '${cfg.listenHost}' "
              + "-p ${toString cfg.port} --max_spare_servers 5 --max_servers 25 "
              + "--max_requests 100 ${optionalString cfg.debugServer "-d"}";
            User = "hydra-www";
            PermissionsStartOnly = true;
            Restart = "always";
          };
      };

    systemd.services.hydra-queue-runner =
      { wantedBy = [ "multi-user.target" ];
        requires = [ "hydra-init.service" ];
        wants = [ "network-online.target" ];
        after = [ "hydra-init.service" "network.target" "network-online.target" ];
        path = [ cfg.package pkgs.nettools pkgs.openssh pkgs.bzip2 config.nix.package ];
        restartTriggers = [ hydraConf ];
        environment = env // {
          PGPASSFILE = "${baseDir}/pgpass-queue-runner"; # grrr
          IN_SYSTEMD = "1"; # to get log severity levels
          HYDRA_DBI = "${env.HYDRA_DBI};application_name=hydra-queue-runner";
        };
        serviceConfig =
          { ExecStart = "@${cfg.package}/bin/hydra-queue-runner hydra-queue-runner -v";
            ExecStopPost = "${cfg.package}/bin/hydra-queue-runner --unlock";
            User = "hydra-queue-runner";
            Restart = "always";

            # Ensure we can get core dumps.
            LimitCORE = "infinity";
            WorkingDirectory = "${baseDir}/queue-runner";
          };
      };

    systemd.services.hydra-evaluator =
      { wantedBy = [ "multi-user.target" ];
        requires = [ "hydra-init.service" ];
        restartTriggers = [ hydraConf ];
        after = [ "hydra-init.service" "network.target" ];
        path = with pkgs; [ nettools cfg.package jq ];
        environment = env // {
          HYDRA_DBI = "${env.HYDRA_DBI};application_name=hydra-evaluator";
        };
        serviceConfig =
          { ExecStart = "@${cfg.package}/bin/hydra-evaluator hydra-evaluator";
            ExecStopPost = "${cfg.package}/bin/hydra-evaluator --unlock";
            User = "hydra";
            Restart = "always";
            WorkingDirectory = baseDir;
          };
      };

    systemd.services.hydra-update-gc-roots =
      { requires = [ "hydra-init.service" ];
        after = [ "hydra-init.service" ];
        environment = env // {
          HYDRA_DBI = "${env.HYDRA_DBI};application_name=hydra-update-gc-roots";
        };
        serviceConfig =
          { ExecStart = "@${cfg.package}/bin/hydra-update-gc-roots hydra-update-gc-roots";
            User = "hydra";
          };
        startAt = "2,14:15";
      };

    systemd.services.hydra-send-stats =
      { wantedBy = [ "multi-user.target" ];
        after = [ "hydra-init.service" ];
        environment = env // {
          HYDRA_DBI = "${env.HYDRA_DBI};application_name=hydra-send-stats";
        };
        serviceConfig =
          { ExecStart = "@${cfg.package}/bin/hydra-send-stats hydra-send-stats";
            User = "hydra";
          };
      };

    systemd.services.hydra-notify =
      { wantedBy = [ "multi-user.target" ];
        requires = [ "hydra-init.service" ];
        after = [ "hydra-init.service" ];
        restartTriggers = [ hydraConf ];
        path = [ pkgs.zstd ];
        environment = env // {
          PGPASSFILE = "${baseDir}/pgpass-queue-runner"; # grrr
          HYDRA_DBI = "${env.HYDRA_DBI};application_name=hydra-notify";
        };
        serviceConfig =
          { ExecStart = "@${cfg.package}/bin/hydra-notify hydra-notify";
            # FIXME: run this under a less privileged user?
            User = "hydra-queue-runner";
            Restart = "always";
            RestartSec = 5;
          };
      };

    # If there is less than a certain amount of free disk space, stop
    # the queue/evaluator to prevent builds from failing or aborting.
    # Leaves a tag file indicating this reason; if the tag file exists
    # and disk space is above the threshold + 10GB, the queue/evaluator will be
    # restarted; starting it if it is already started is not harmful.
    systemd.services.hydra-check-space =
      { script =
          ''
            spaceleft=$(($(stat -f -c '%a' /nix/store) * $(stat -f -c '%S' /nix/store)))
            spacestopstart() {
              service=$1
              minFreeGB=$2
              if [ $spaceleft -lt $(($minFreeGB * 1024**3)) ]; then
                if [ $(systemctl is-active $service) == active ]; then
                  echo "stopping $service due to lack of free space..."
                  systemctl stop $service
                  date > ${baseDir}/.$service-stopped-minspace
                fi
              else
                if [ $spaceleft -gt $(( ($minFreeGB + 10) * 1024**3)) -a \
                     -r ${baseDir}/.$service-stopped-minspace ] ; then
                  rm ${baseDir}/.$service-stopped-minspace
                  echo "restarting $service due to newly available free space..."
                  systemctl start $service
                fi
              fi
            }
            spacestopstart hydra-queue-runner ${toString cfg.minimumDiskFree}
            spacestopstart hydra-evaluator ${toString cfg.minimumDiskFreeEvaluator}
          '';
        startAt = "*:0/5";
      };

    # Periodically compress build logs. The queue runner compresses
    # logs automatically after a step finishes, but this doesn't work
    # if the queue runner is stopped prematurely.
    systemd.services.hydra-compress-logs =
      { path = [ pkgs.bzip2 pkgs.zstd ];
        script =
          ''
            set -eou pipefail
            compression=$(sed -nr 's/compress_build_logs_compression = ()/\1/p' ${baseDir}/hydra.conf)
            if [[ $compression == "" ]]; then
              compression="bzip2"
            elif [[ $compression == zstd ]]; then
              compression="zstd --rm"
            fi
            find ${baseDir}/build-logs -ignore_readdir_race -type f -name "*.drv" -mtime +3 -size +0c | xargs -r "$compression" --force --quiet
          '';
        startAt = "Sun 01:45";
      };

    services.postgresql.enable = mkIf haveLocalDB true;

    services.postgresql.identMap = optionalString haveLocalDB
      ''
        hydra-users hydra hydra
        hydra-users hydra-queue-runner hydra
        hydra-users hydra-www hydra
        hydra-users root hydra
        # The postgres user is used to create the pg_trgm extension for the hydra database
        hydra-users postgres postgres
      '';

    services.postgresql.authentication = optionalString haveLocalDB
      ''
        local hydra all ident map=hydra-users
      '';

  };

}

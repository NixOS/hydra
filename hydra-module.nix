{ config, pkgs, ... }:

with pkgs.lib;

let
  cfg = config.services.hydra;

  baseDir = "/var/lib/hydra";

  hydraConf = pkgs.writeScript "hydra.conf" cfg.extraConfig;

  env =
    { NIX_REMOTE = "daemon";
      HYDRA_DBI = cfg.dbi;
      HYDRA_CONFIG = "${baseDir}/data/hydra.conf";
      HYDRA_DATA = "${baseDir}/data";
      HYDRA_PORT = "${toString cfg.port}";
      OPENSSL_X509_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt";
      GIT_SSL_CAINFO = "/etc/ssl/certs/ca-bundle.crt";
    };

  serverEnv = env //
    { HYDRA_LOGO = if cfg.logo != null then cfg.logo else "";
      HYDRA_TRACKER = cfg.tracker;
    } // (optionalAttrs cfg.debugServer { DBIC_TRACE = 1; });
in

{
  ###### interface
  options = {
    services.hydra = rec {

      enable = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to run Hydra services.
        '';
      };

      dbi = mkOption {
        type = types.string;
        default = "dbi:Pg:dbname=hydra;user=hydra;";
        example = "dbi:Pg:dbname=hydra;host=postgres.example.org;user=foo;";
        description = ''
          The DBI string for Hydra database connection.
        '';
      };

      package = mkOption {
        type = types.path;
        #default = pkgs.hydra;
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
        default = 5;
        description = ''
          Threshold of minimum disk space (GiB) to determine if queue runner should run or not.
        '';
      };

      minimumDiskFreeEvaluator = mkOption {
        type = types.int;
        default = 2;
        description = ''
          Threshold of minimum disk space (GiB) to determine if evaluator should run or not.
        '';
      };

      notificationSender = mkOption {
        type = types.str;
        description = ''
          Sender email address used for email notifications.
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
        type = types.nullOr types.str;
        default = null;
        description = ''
          File name of an alternate logo to be displayed on the web pages.
        '';
      };

      debugServer = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to run the server in debug mode";
      };

      extraConfig = mkOption {
        type = types.lines;
        description = "Extra lines for the hydra config";
      };

    };

  };


  ###### implementation

  config = mkIf cfg.enable {
    services.hydra.extraConfig =
      ''
        using_frontend_proxy 1
        base_uri ${cfg.hydraURL}
        notification_sender ${cfg.notificationSender}
        max_servers 25
      '';

    environment.systemPackages = [ cfg.package ];

    users.extraUsers.hydra =
      { description = "Hydra";
        home = baseDir;
        createHome = true;
        useDefaultShell = true;
      };

    nix.extraOptions = ''
      gc-keep-outputs = true
      gc-keep-derivations = true

      # The default (`true') slows Nix down a lot since the build farm
      # has so many GC roots.
      gc-check-reachability = false

      # Hydra needs caching of build failures.
      build-cache-failure = true

      build-poll-interval = 10

      # Online log compression makes it impossible to get the tail of
      # builds that are in progress.
      build-compress-log = false
    '';

    systemd.services."hydra-init" =
      { wantedBy = [ "multi-user.target" ];
        requires = [ "postgresql.service" ];
        after = [ "postgresql.service" ];
        environment = env;
        script = ''
          mkdir -p ${baseDir}/data
          chown hydra ${baseDir}/data
          ln -sf ${hydraConf} ${baseDir}/data/hydra.conf
          ${optionalString (cfg.dbi == "dbi:Pg:dbname=hydra;user=hydra;") ''
            if ! [ -e ${baseDir}/.db-created ]; then
              ${config.services.postgresql.package}/bin/createuser hydra
              ${config.services.postgresql.package}/bin/createdb -O hydra hydra
              touch ${baseDir}/.db-created
            fi
          ''}
          ${pkgs.shadow}/bin/su hydra -c ${cfg.package}/bin/hydra-init
        '';
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
      };

    systemd.services."hydra-server" =
      { wantedBy = [ "multi-user.target" ];
        requires = [ "hydra-init.service" ];
        after = [ "hydra-init.service" ];
        environment = serverEnv;
        serviceConfig =
          { ExecStart = "@${cfg.package}/bin/hydra-server hydra-server -f -h '${cfg.listenHost}' --max_spare_servers 5 --max_servers 25 --max_requests 100${optionalString cfg.debugServer " -d"}";
            User = "hydra";
            Restart = "always";
          };
      };

    systemd.services."hydra-queue-runner" =
      { wantedBy = [ "multi-user.target" ];
        requires = [ "hydra-init.service" ];
        after = [ "hydra-init.service" "network.target" ];
        path = [ pkgs.nettools ];
        environment = env;
        serviceConfig =
          { ExecStartPre = "${cfg.package}/bin/hydra-queue-runner --unlock";
            ExecStart = "@${cfg.package}/bin/hydra-queue-runner hydra-queue-runner";
            User = "hydra";
            Restart = "always";
          };
      };

    systemd.services."hydra-evaluator" =
      { wantedBy = [ "multi-user.target" ];
        requires = [ "hydra-init.service" ];
        after = [ "hydra-init.service" "network.target" ];
        path = [ pkgs.nettools ];
        environment = env;
        serviceConfig =
          { ExecStart = "@${cfg.package}/bin/hydra-evaluator hydra-evaluator";
            User = "hydra";
            Restart = "always";
          };
      };

    systemd.services."hydra-update-gc-roots" =
      { requires = [ "hydra-init.service" ];
        after = [ "hydra-init.service" ];
        environment = env;
        serviceConfig =
          { ExecStart = "@${cfg.package}/bin/hydra-update-gc-roots hydra-update-gc-roots";
            User = "hydra";
          };
      };

    services.cron.systemCronJobs =
      let
        # If there is less than ... GiB of free disk space, stop the queue
        # to prevent builds from failing or aborting.
        checkSpace = pkgs.writeScript "hydra-check-space"
          ''
            #! ${pkgs.stdenv.shell}
            if [ $(($(stat -f -c '%a' /nix/store) * $(stat -f -c '%S' /nix/store))) -lt $((${toString cfg.minimumDiskFree} * 1024**3)) ]; then
                systemctl stop hydra-queue-runner
            fi
            if [ $(($(stat -f -c '%a' /nix/store) * $(stat -f -c '%S' /nix/store))) -lt $((${toString cfg.minimumDiskFreeEvaluator} * 1024**3)) ]; then
                systemctl stop hydra-evaluator
            fi
          '';

        compressLogs = pkgs.writeScript "compress-logs" ''
           #! ${pkgs.stdenv.shell} -e
           find /nix/var/log/nix/drvs \
                -type f -a ! -newermt 'last month' \
                -name '*.drv' -exec bzip2 -v {} +
         '';
      in
        [ "*/5 * * * * root  ${checkSpace} &> ${baseDir}/data/checkspace.log"
          "15 5 * * * root  ${compressLogs} &> ${baseDir}/data/compress.log"
          "15 2 * * * root  ${pkgs.systemd}/bin/systemctl start hydra-update-gc-roots.service"
        ];
  };
}

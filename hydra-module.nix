{ config, pkgs, ... }:

with pkgs.lib;

let
  cfg = config.services.hydra;

  hydraConf = pkgs.writeScript "hydra.conf" 
    ''
      using_frontend_proxy 1
      base_uri ${cfg.hydraURL}
      notification_sender ${cfg.notificationSender}
      max_servers 25
    '';
    
  env = ''export NIX_REMOTE=daemon ''
      + ''HYDRA_DBI="${cfg.dbi}" ''
      + ''HYDRA_CONFIG=${cfg.baseDir}/data/hydra.conf ''
      + ''HYDRA_DATA=${cfg.baseDir}/data ''
      + ''HYDRA_PORT="${toString cfg.port}" ''
      + (if cfg.logo != null
         then ''HYDRA_LOGO="${cfg.logo}" ''
         else "")
      + ''HYDRA_TRACKER="${cfg.tracker}" ;'';

in

{
  ###### interface
  options = {
    services.hydra = rec {
        
      enable = mkOption {
        default = false;
        description = ''
          Whether to run Hydra services.
        '';
      };

      baseDir = mkOption {
        default = "/home/${user.default}";
        description = ''
          The directory holding configuration, logs and temporary files.
        '';
      };

      user = mkOption {
        default = "hydra";
        description = ''
          The user the Hydra services should run as.
        '';
      };
      
      dbi = mkOption {
        default = "dbi:Pg:dbname=hydra;host=localhost;user=root;";
        example = "dbi:SQLite:/home/hydra/db/hydra.sqlite";
        description = ''
          The DBI string for Hydra database connection.
        '';
      };
      
      hydra = mkOption {
        default = pkgs.hydra;
        description = ''
          Location of hydra
        '';
      };
      
      hydraURL = mkOption {
        default = "http://hydra.nixos.org";
        description = ''
          The base URL for the Hydra webserver instance. Used for links in emails. 
        '';
      };

      port = mkOption {
        default = 3000;
        description = ''
          TCP port the web server should listen to.
        '';
      };

      minimumDiskFree = mkOption {
        default = 5;
        description = ''
          Threshold of minimum disk space (G) to determine if queue runner should run or not.  
        '';
      };

      minimumDiskFreeEvaluator = mkOption {
        default = 2;
        description = ''
          Threshold of minimum disk space (G) to determine if evaluator should run or not.  
        '';
      };

      notificationSender = mkOption {
        default = "e.dolstra@tudelft.nl";
        description = ''
          Sender email address used for email notifications. 
        '';
      }; 

      tracker = mkOption {
        default = "";
        description = ''
          Piece of HTML that is included on all pages.
        '';
      };

      logo = mkOption {
        default = null;
        description = ''
          File name of an alternate logo to be displayed on the web pages.
        '';
      };

      autoStart = mkOption {
        default = true;
        description = ''
          If hydra upstart jobs should start automatically.
        '';
      }; 
      
    };

  };
  

  ###### implementation

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.hydra ];

    users.extraUsers = [
      { name = cfg.user;
        description = "Hydra";
        home = cfg.baseDir;
        createHome = true;
        useDefaultShell = true;
      } 
    ];

    # We have our own crontab entries for GC, see below.
    nix.gc.automatic = false;

    nix.extraOptions = ''
      gc-keep-outputs = true
      gc-keep-derivations = true

      # The default (`true') slows Nix down a lot since the build farm
      # has so many GC roots.
      gc-check-reachability = false

      # Hydra needs caching of build failures.
      build-cache-failure = true

      build-poll-interval = 10

      use-sqlite-wal = false
    '';

    jobs.hydra_init =
      { description = "hydra-init";
        startOn = "started network-interfaces";
        preStart = ''
          mkdir -p ${cfg.baseDir}/data
          chown ${cfg.user} ${cfg.baseDir}/data
          ln -sf ${hydraConf} ${cfg.baseDir}/data/hydra.conf
        '';
        exec = ''
          echo done
        '';
      };

    jobs.hydra_server =
      { description = "hydra-server";
        startOn = if cfg.autoStart then "started network-interfaces hydra-init" else "never";
        exec = ''
          ${pkgs.su}/bin/su - ${cfg.user} -c '${env} ${cfg.hydra}/bin/hydra-server > ${cfg.baseDir}/data/server.log 2>&1'
        '';
      };

    jobs.hydra_queue_runner =
      { description = "hydra-queue-runner";
        startOn = if cfg.autoStart then "started network-interfaces hydra-init" else "never";
        preStart = "${pkgs.su}/bin/su - ${cfg.user} -c '${env} ${cfg.hydra}/bin/hydra-queue-runner --unlock'";
        exec = ''
          ${pkgs.su}/bin/su - ${cfg.user} -c '${env} nice -n 8 ${cfg.hydra}/bin/hydra-queue-runner > ${cfg.baseDir}/data/queue-runner.log 2>&1'
        '';
      };

    jobs.hydra_evaluator =
      { description = "hydra-evaluator";
        startOn = if cfg.autoStart then "started network-interfaces hydra-init" else "never";
        exec = ''
          ${pkgs.su}/bin/su - ${cfg.user} -c '${env} nice -n 5 ${cfg.hydra}/bin/hydra-evaluator > ${cfg.baseDir}/data/evaluator.log 2>&1'
        '';
      };

    services.cron.systemCronJobs =
      let
        # If there is less than ... GiB of free disk space, stop the queue
        # to prevent builds from failing or aborting.
        checkSpace = pkgs.writeScript "hydra-check-space"
          ''
            #! /bin/sh
            if [ $(($(stat -f -c '%a' /nix/store) * $(stat -f -c '%S' /nix/store))) -lt $((${toString cfg.minimumDiskFree} * 1024**3)) ]; then
          stop hydra_queue_runner
            fi
        if [ $(($(stat -f -c '%a' /nix/store) * $(stat -f -c '%S' /nix/store))) -lt $((${toString cfg.minimumDiskFreeEvaluator} * 1024**3)) ]; then
          stop hydra_evaluator
        fi
          '';

        collect = pkgs.writeScript "collect-some-garbage"
          # Arrange to always have at least 100 GiB free.
          '' #!/bin/sh -e
             available="$(df -B1 /nix/store | tail -n 1 | awk '{ print $4 }')"
             target="$((100 * 1024**3))"
             to_free="$(($available > $target ? 200 * 1024**2 : $target - $available))"

             echo "$available B available, and targeting $target B available"
             echo "thus, freeing $to_free B"
             exec "${pkgs.nix}/bin/nix-collect-garbage" --max-freed "$to_free"
          '';

        compressLogs = pkgs.writeScript "compress-logs" ''
            #! /bin/sh -e
           touch -d 'last month' r
           find /nix/var/log/nix/drvs -type f -a ! -newer r -name '*.drv' | xargs bzip2 -v
         '';
      in
        [ "15 03 * * * root  ${collect} &> ${cfg.baseDir}/data/gc.log"
          "15 13 * * * root  ${collect} &> ${cfg.baseDir}/data/gc.log"

          "*/5 * * * * root  ${checkSpace} &> ${cfg.baseDir}/data/checkspace.log"

          "15 5 * * * root  ${compressLogs} &> ${cfg.baseDir}/data/compress.log"
          "15 02 * * * ${cfg.user} ${env} ${cfg.hydra}/bin/hydra-update-gc-roots &> ${cfg.baseDir}/data/gc-roots.log"
        ];
  };
}

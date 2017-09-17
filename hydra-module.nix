{ config, pkgs, lib ? pkgs.lib, ... }:

# ------------------------------------------------------------------------------
# FIXME: send this stuff upstream to nixpkgs
# vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv

with {
  lib = lib // rec {
    forceWHNF = x: builtins.seq x x;
    forceDeep = x: builtins.deepSeq x x;

    strings = lib.strings // {
      intercalate = str: list: lib.concatStrings (lib.intersperse str list);
    };

    lists = lib.lists // (
      with {
        foldToFold1 = fold: (f: list: (
          assert builtins.length list > 0;
          with {
            mlist = builtins.map (x: { v = x; }) list;
            merge = a: b: (
              if a != null
              then (if b != null then { v = f a.v b.v; } else a)
              else (if b != null then b                  else null));
          };
          (fold merge null mlist).value));
      };

      {
        foldr   = lib.lists.fold;
        foldr1  = foldToFold1 lists.foldr;
        foldl   = lib.lists.foldl;
        foldl1  = foldToFold1 lists.foldl;
        foldl'  = lib.lists.foldl';
        foldl1' = foldToFold1 lists.foldl';
      });

    regex = {
      # renderRegex
      #   :: (∀ r . { lit : String → r, alt : [r] → r, star : r → r } → r)
      #   -> Regex
      renderRegex = expr: expr {
        lit  = str: str;
        alt  = rxs: "(" + strings.intercalate "|" rxs + ")";
        star = rx: "(" + rx + ")*";
      };
    };

    types = lib.types // {
      oneof = list: (
        assert lib.isList list;
        assert lib.all lib.isOptionType list;

        if lib.length list > 0
        then lists.foldr1 lib.types.either list
        else throw "lib.types.oneof: empty list");

      matching = rx: type: (
        lib.types.addCheck type
        (str: assert isString str; builtins.match rx str != null));
    };
  };
};

# ∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧∧
# ------------------------------------------------------------------------------

with lib;

with rec {
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
  } // optionalAttrs (cfg.smtpHost != null) {
    EMAIL_SENDER_TRANSPORT = "SMTP";
    EMAIL_SENDER_TRANSPORT_host = cfg.smtpHost;
  } // hydraEnv // cfg.extraEnv;

  serverEnv = env // {
    HYDRA_TRACKER = cfg.tracker;
    COLUMNS = "80";
    PGPASSFILE = "${baseDir}/pgpass-www"; # grrr
  } // (optionalAttrs cfg.debugServer { DBIC_TRACE = "1"; });

  localDB = "dbi:Pg:dbname=hydra;user=hydra;";

  haveLocalDB = cfg.dbi == localDB;

  hydraExe = name: "${cfg.package}/bin/${name}";

  googleOAuthDocs =
    "https://developers.google.com/identity/sign-in/web/devconsole-project";
};

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
        '';
      };

      package = mkOption {
        type = types.package;
        default = pkgs.hydra;
        description = "The Hydra package.";
      };

      hydraURL = mkOption {
        type = types.str;
        description = ''
          The base URL for the Hydra webserver instance.
          Used for links in emails.
        '';
      };

      listenHost = mkOption {
        type = types.str;
        default = "*";
        example = "localhost";
        description = ''
          The hostname or address to listen on.
          If <literal>*</literal> is given, listen on all interfaces.
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
          Threshold of minimum disk space (GiB) to determine if the queue
          runner should run or not.
        '';
      };

      minimumDiskFreeEvaluator = mkOption {
        type = types.int;
        default = 0;
        description = ''
          Threshold of minimum disk space (GiB) to determine if the evaluator
          should run or not.
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
        default = ["/etc/nix/machines"];
        example = ["/etc/nix/machines" "/var/lib/hydra/provisioner/machines"];
        description = "List of files containing build machines.";
      };

      useSubstitutes = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to use binary caches for downloading store paths. Note that
          binary substitutions trigger a potentially large number of additional
          HTTP requests that slow down the queue monitor thread significantly.
          Also, this Hydra instance will serve those downloaded store paths to
          its users with its own signature attached as if it had built them
          itself, so don't enable this feature unless your active binary caches
          are absolute trustworthy.
        '';
      };

      googleClientID = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "35009a79-1a05-49d7-b876-2b884d0f825b";
        description = ''
          The Google API client ID to use in the Hydra Google OAuth login.

          More information is available
          <ulink url="${googleOAuthDocs}">here</ulink>.
        '';
      };

      private = mkOption {
        type = types.bool;
        default = false;
        example = true;
        description = ''
          FIXME: doc
        '';
      };

      maxServers = mkOption {
        type = types.int;
        default = 25;
        description = ''
          FIXME: doc
        '';
      };

      compressThreads = mkOption {
        type = types.int;
        default = 0;
        description = ''
          FIXME: doc
        '';
      };

      storeURI = mkOption {
        type = (
          types.matching "^(file|s3)://(.*)(|?secret-key=(.*))$" types.str);
        default = 0;
        description = ''
          FIXME: doc
        '';
      };

    };

  };

  ###### implementation

  config = mkIf cfg.enable {

    users.extraGroups.hydra = {};

    users.extraUsers.hydra = {
      description     = "Hydra";
      group           = "hydra";
      createHome      = true;
      home            = baseDir;
      useDefaultShell = true;
    };

    users.extraUsers.hydra-queue-runner = {
      description     = "Hydra queue runner";
      group           = "hydra";
      useDefaultShell = true;
      home            = "${baseDir}/queue-runner"; # <-- keeps SSH happy
    };

    users.extraUsers.hydra-www = {
      description     = "Hydra web server";
      group           = "hydra";
      useDefaultShell = true;
    };

    nix.trustedUsers = ["hydra-queue-runner"];

    services.hydra-dev.package = (
      mkDefault ((import ./release.nix {}).build.x86_64-linux));

    services.hydra-dev.extraConfig = ''
      using_frontend_proxy = 1
      base_uri = ${cfg.hydraURL}
      notification_sender = ${cfg.notificationSender}
      max_servers = ${toString cfg.maxServers}
      compress_num_threads = ${toString cfg.compressThreads}
      ${optionalString (cfg.logo != null) "hydra_logo = ${cfg.logo}"}
      gc_roots_dir = ${cfg.gcRootsDir}
      use-substitutes = ${if cfg.useSubstitutes then "1" else "0"}
      ${optionalString (cfg.googleClientID != null) ''
        enable_google_login = 1
        google_client_id = ${cfg.googleClientID}
      ''}
      private = ${if cfg.private then "1" else "0"}
      ${optionalString (cfg.logPrefix != null) "log_prefix = ${cfg.logPrefix}"}
    '';

    # FIXME: add/investigate all of these:
    # - compress_build_logs = …
    # - compression_type = …
    # - allowed_domains = …
    # - max_db_connections = int
    # - nar_buffer_size = int
    # - max_output_size = int
    # - upload_logs_to_binary_cache = bool
    # - xxx-jobset-repeats = string
    # - max-concurrent-notifications = int

    environment.systemPackages = [cfg.package];

    environment.variables = hydraEnv;

    nix.extraOptions = ''
      gc-keep-outputs = true
      gc-keep-derivations = true

      # The default (`true') slows Nix down a lot since the build farm
      # has so many GC roots.
      gc-check-reachability = false
    '';

    systemd.services.hydra-init = {
      wantedBy = ["multi-user.target"];
      requires = optional haveLocalDB "postgresql.service";
      after = optional haveLocalDB "postgresql.service";
      environment = env;
      preStart = ''
        mkdir -p ${baseDir}
        chown hydra.hydra ${baseDir}
        chmod 0750 ${baseDir}

        ln -sf ${hydraConf} ${baseDir}/hydra.conf

        mkdir -m 0700 -p ${baseDir}/www
        chown hydra-www.hydra ${baseDir}/www

        mkdir -m 0700 -p ${baseDir}/queue-runner
        mkdir -m 0750 -p ${baseDir}/build-logs
        chown hydra-queue-runner.hydra ${baseDir}/queue-runner
        chown hydra-queue-runner.hydra ${baseDir}/build-logs

        ${optionalString haveLocalDB ''
          if ! [ -e ${baseDir}/.db-created ]; then
              ${config.services.postgresql.package}/bin/createuser hydra
              ${config.services.postgresql.package}/bin/createdb -O hydra hydra
              touch ${baseDir}/.db-created
          fi
        ''}

        if [ ! -e ${cfg.gcRootsDir} ]; then
            # Move legacy roots directory.
            if [ -e /nix/var/nix/gcroots/per-user/hydra/hydra-roots ]; then
                mv /nix/var/nix/gcroots/per-user/hydra/hydra-roots \
                   ${cfg.gcRootsDir}
            fi

            mkdir -p ${cfg.gcRootsDir}
        fi

        # Move legacy hydra-www roots.
        if [ -e /nix/var/nix/gcroots/per-user/hydra-www/hydra-roots ]; then
            find /nix/var/nix/gcroots/per-user/hydra-www/hydra-roots/ -type f \
                | xargs -r mv -f -t ${cfg.gcRootsDir}/
            rmdir /nix/var/nix/gcroots/per-user/hydra-www/hydra-roots
        fi

        chown hydra.hydra ${cfg.gcRootsDir}
        chmod 2775 ${cfg.gcRootsDir}
      '';

      serviceConfig = {
        ExecStart            = hydraExe "hydra-init";
        PermissionsStartOnly = true;
        User                 = "hydra";
        Type                 = "oneshot";
        RemainAfterExit      = true;
      };
    };

    systemd.services.hydra-server = {
      wantedBy = ["multi-user.target"];
      requires = ["hydra-init.service"];
      after = ["hydra-init.service"];
      environment = serverEnv;
      restartTriggers = [hydraConf];
      serviceConfig = {
        ExecStart = ("@${hydraExe "hydra-server"} hydra-server " + (
          lib.concatStrings (lib.intersperse " " (filter builtins.isString [
            "-f"
            "-h '${cfg.listenHost}'"
            "-p ${toString cfg.port}"
            "--max_spare_servers 5"
            "--max_servers 25"
            "--max_requests 100"
            (if cfg.debugServer then "-d" else null)
          ]))));
        User                 = "hydra-www";
        PermissionsStartOnly = true;
        Restart              = "always";
      };
    };

    systemd.services.hydra-queue-runner = {
      wantedBy = ["multi-user.target"];
      requires = ["hydra-init.service"];
      after = ["hydra-init.service" "network.target"];
      path = [
        cfg.package
        pkgs.nettools
        pkgs.openssh
        pkgs.bzip2
        config.nix.package
      ];
      restartTriggers = [hydraConf];
      environment = env // {
        PGPASSFILE = "${baseDir}/pgpass-queue-runner"; # grrr
        IN_SYSTEMD = "1"; # to get log severity levels
      };
      serviceConfig = {
        ExecStart        = "@${hydraExe "hydra-queue-runner"} hydra-queue-runner -v";
        ExecStopPost     = "${hydraExe "hydra-queue-runner"} --unlock";
        User             = "hydra-queue-runner";
        Restart          = "always";
        LimitCORE        = "infinity"; # <-- ensure we can get core dumps.
        WorkingDirectory = "${baseDir}/queue-runner";
      };
    };

    systemd.services.hydra-evaluator = {
      wantedBy = ["multi-user.target"];
      requires = ["hydra-init.service"];
      restartTriggers = [hydraConf];
      after = ["hydra-init.service" "network.target"];
      path = with pkgs; [nettools cfg.package jq];
      environment = env;
      serviceConfig = {
        ExecStart        = "@${hydraExe "hydra-evaluator"} hydra-evaluator";
        ExecStopPost     = "${hydraExe "hydra-evaluator"} --unlock";
        User             = "hydra";
        Restart          = "always";
        WorkingDirectory = baseDir;
      };
    };

    systemd.services.hydra-update-gc-roots = {
      requires = ["hydra-init.service"];
      after = ["hydra-init.service"];
      environment = env;
      serviceConfig = {
        ExecStart = "@${hydraExe "hydra-update-gc-roots"} hydra-update-gc-roots";
        User      = "hydra";
      };
      startAt = "2,14:15";
    };

    systemd.services.hydra-send-stats = {
      wantedBy = ["multi-user.target"];
      after = ["hydra-init.service"];
      environment = env;
      serviceConfig = {
        ExecStart = "@${hydraExe "hydra-send-stats"} hydra-send-stats";
        User      = "hydra";
      };
    };

    # If there is less than a certain amount of free disk space, stop
    # the queue/evaluator to prevent builds from failing or aborting.
    systemd.services.hydra-check-space = {
      script = ''
        FREE_BLOCKS="$(stat -f -c '%a' /nix/store)"
        BLOCK_SIZE="$(stat -f -c '%S' /nix/store)"
        FREE_BYTES="$((FREE_BLOCKS * BLOCK_SIZE))"
        QUEUE_MIN_FREE_GB="${toString cfg.minimumDiskFree}"
        QUEUE_MIN_FREE_BYTES="$((QUEUE_MIN_FREE_GB * 1024**3))"
        EVAL_MIN_FREE_GB="${toString cfg.minimumDiskFreeEvaluator}"
        EVAL_MIN_FREE_BYTES="$((EVAL_MIN_FREE_GB * 1024**3))"

        if (( FREE_BYTES < QUEUE_MIN_FREE_BYTES )); then
            echo "stopping Hydra queue runner due to lack of free space..."
            systemctl stop hydra-queue-runner
        fi
        if (( FREE_BYTES < EVAL_MIN_FREE_BYTES )); then
            echo "stopping Hydra evaluator due to lack of free space..."
            systemctl stop hydra-evaluator
        fi
      '';
      startAt = "*:0/5";
    };

    # Periodically compress build logs. The queue runner compresses
    # logs automatically after a step finishes, but this doesn't work
    # if the queue runner is stopped prematurely.
    systemd.services.hydra-compress-logs = {
      path = [pkgs.bzip2];
      # FIXME: use `find … -print0` and `xargs -0` here
      # FIXME: perhaps use GNU parallel instead of xargs
      script = ''
        find /var/lib/hydra/build-logs -type f -name "*.drv" -mtime +3 -size +0c \
            | xargs -r bzip2 -v -f
      '';
      startAt = "Sun 01:45";
    };

    services.postgresql.enable = mkIf haveLocalDB true;

    services.postgresql.identMap = optionalString haveLocalDB ''
      hydra-users hydra hydra
      hydra-users hydra-queue-runner hydra
      hydra-users hydra-www hydra
      hydra-users root hydra
    '';

    services.postgresql.authentication = optionalString haveLocalDB ''
      local hydra all ident map=hydra-users
    '';
  };
}

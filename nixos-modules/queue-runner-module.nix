{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.queue-runner-dev;

  format = pkgs.formats.toml { };
in
{
  options = {
    services.queue-runner-dev = {
      enable = lib.mkEnableOption "QueueRunner";

      settings = lib.mkOption {
        description = "Reloadable settings for queue runner";
        type = lib.types.submodule {
          options = {
            hydraDataDir = lib.mkOption {
              description = "Hydra data directory";
              type = lib.types.path;
              default = "/var/lib/hydra";
            };
            dbUrl = lib.mkOption {
              description = "Postgresql database url";
              type = lib.types.singleLineStr;
              default = "postgres://hydra@%2Frun%2Fpostgresql:5432/hydra";
            };
            maxDbConnections = lib.mkOption {
              description = "Postgresql maximum db connections";
              type = lib.types.ints.positive;
              default = 128;
            };
            machineSortFn = lib.mkOption {
              description = "Function name for sorting machines";
              type = lib.types.enum [
                "SpeedFactorOnly"
                "CpuCoreCountWithSpeedFactor"
                "BogomipsWithSpeedFactor"
              ];
              default = "SpeedFactorOnly";
            };
            machineFreeFn = lib.mkOption {
              description = "Function name for determining \"idle\" machines";
              type = lib.types.enum [
                "Dynamic"
                "DynamicWithMaxJobLimit"
                "Static"
              ];
              default = "Static";
            };
            stepSortFn = lib.mkOption {
              description = "Function name for sorting steps/jobs";
              type = lib.types.enum [
                "Legacy"
                "WithRdeps"
              ];
              default = "WithRdeps";
            };
            dispatchTriggerTimerInS = lib.mkOption {
              description = "Timer for triggering dispatch in an interval in seconds. Setting this to a value <= 0 will disable this timer and only trigger the dispatcher if queue changes happend.";
              type = lib.types.int;
              default = 120;
            };
            queueTriggerTimerInS = lib.mkOption {
              description = "Timer for triggering queue in an interval in seconds. Setting this to a value <= 0 will disable this timer and only trigger via pg notifications.";
              type = lib.types.int;
              default = -1;
            };
            remoteStoreAddr = lib.mkOption {
              description = "Remote store address";
              type = lib.types.listOf lib.types.singleLineStr;
              default = [ ];
            };
            useSubstitutes = lib.mkOption {
              description = "Use substitution for paths";
              type = lib.types.bool;
              default = false;
            };
            rootsDir = lib.mkOption {
              description = "Gcroots directory, defaults to /nix/var/nix/gcroots/per-user/$LOGNAME/hydra-roots";
              type = lib.types.nullOr lib.types.path;
              default = null;
            };
            maxRetries = lib.mkOption {
              description = "Number of maximum amount of retries for a build step.";
              type = lib.types.ints.positive;
              default = 5;
            };
            retryInterval = lib.mkOption {
              description = "Interval in which retires should be able to be attempted again.";
              type = lib.types.ints.positive;
              default = 60;
            };
            retryBackoff = lib.mkOption {
              description = "Additional backoff on top of the retry interval.";
              type = lib.types.float;
              default = 3.0;
            };
            maxUnsupportedTimeInS = lib.mkOption {
              description = "Time until unsupported steps are aborted.";
              type = lib.types.ints.unsigned;
              default = 120;
            };
            stopQueueRunAfterInS = lib.mkOption {
              description = "Seconds after which the queue run should be interupted early. Setting this to a value <= 0 will disable this feature and the queue run will never exit early.";
              type = lib.types.int;
              default = 60;
            };
            maxConcurrentDownloads = lib.mkOption {
              description = "Max count of concurrent downloads per build. Increasing this will increase memory usage of the queue runner.";
              type = lib.types.ints.positive;
              default = 5;
            };
            concurrentUploadLimit = lib.mkOption {
              description = "Concurrent limit for uploading to s3.";
              type = lib.types.ints.positive;
              default = 5;
            };
            tokenListPath = lib.mkOption {
              description = "Path to a list of allowed authentication tokens.";
              type = lib.types.nullOr lib.types.path;
              default = null;
            };
            enableFodChecker = lib.mkOption {
              description = "This will enable the FOD checker. It will collect FOD in a separate queue and scheudle these builds to a separate machine with the mandatory feature FOD.";
              type = lib.types.bool;
              default = false;
            };
            usePresignedUploads = lib.mkOption {
              description = ''
                If enabled the queue runner will no longer upload to s3 but rather the builder will do the uploads.
                This also requires a s3 remote store, as well as substitution on the builders.
                You can use forcedSubstituters setting to specify the required substituter on the builders.
              '';
              type = lib.types.bool;
              default = false;
            };
            forcedSubstituters = lib.mkOption {
              description = "Force a list of substituters per builder. Builder will no longer be accepted if they don't have `useSubstitutes` with the substituters listed here.";
              type = lib.types.listOf lib.types.singleLineStr;
              default = [ ];
            };
          };
        };
        default = { };
      };

      grpc = lib.mkOption {
        description = "grpc options";
        default = { };
        type = lib.types.submodule {
          options = {
            address = lib.mkOption {
              type = lib.types.singleLineStr;
              default = "[::1]";
              description = "The IP address the grpc listener should bound to";
            };

            port = lib.mkOption {
              description = "Which grpc port this app should listen on";
              type = lib.types.port;
              default = 50051;
            };
          };
        };
      };

      rest = lib.mkOption {
        description = "rest options";
        default = { };
        type = lib.types.submodule {
          options = {
            address = lib.mkOption {
              type = lib.types.singleLineStr;
              default = "[::1]";
              description = "The IP address the rest listener should bound to";
            };

            port = lib.mkOption {
              description = "Which rest port this app should listen on";
              type = lib.types.port;
              default = 8080;
            };
          };
        };
      };

      mtls = lib.mkOption {
        description = "mtls options";
        default = null;
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              serverCertPath = lib.mkOption {
                description = "Server certificate path";
                type = lib.types.path;
              };
              serverKeyPath = lib.mkOption {
                description = "Server key path";
                type = lib.types.path;
              };
              clientCaCertPath = lib.mkOption {
                description = "Client ca certificate path";
                type = lib.types.path;
              };
            };
          }
        );
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./. { };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.queue-runner-dev = {
      description = "queue-runner main service";

      requires = [ "nix-daemon.socket" ];
      after = [
        "network.target"
        "postgresql.service"
      ];
      wantedBy = [ "multi-user.target" ];
      reloadTriggers = [ config.environment.etc."hydra/queue-runner.toml".source ];

      environment = {
        NIX_REMOTE = "daemon";
        LIBEV_FLAGS = "4"; # go ahead and mandate epoll(2)
        RUST_BACKTRACE = "1";

        # Note: it's important to set this for nix-store, because it wants to use
        # $HOME in order to use a temporary cache dir. bizarre failures will occur
        # otherwise
        HOME = "/run/queue-runner";
      };

      serviceConfig = {
        Type = "notify";
        Restart = "always";
        RestartSec = "5s";

        ExecStart = lib.escapeShellArgs (
          [
            "${cfg.package}/bin/queue-runner"
            "--rest-bind"
            "${cfg.rest.address}:${toString cfg.rest.port}"
            "--grpc-bind"
            "${cfg.grpc.address}:${toString cfg.grpc.port}"
            "--config-path"
            "/etc/hydra/queue-runner.toml"
          ]
          ++ lib.optionals (cfg.mtls != null) [
            "--server-cert-path"
            cfg.mtls.serverCertPath
            "--server-key-path"
            cfg.mtls.serverKeyPath
            "--client-ca-cert-path"
            cfg.mtls.clientCaCertPath
          ]
        );
        ExecReload = "${pkgs.util-linux}/bin/kill -HUP $MAINPID";

        User = "hydra-queue-runner";
        Group = "hydra";

        PrivateNetwork = false;
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        StateDirectory = [ "hydra/queue-runner" ];
        StateDirectoryMode = "0700";
        ReadWritePaths = [
          "/nix/var/nix/gcroots/"
          "/run/postgresql/.s.PGSQL.${toString config.services.postgresql.settings.port}"
          "/nix/var/nix/daemon-socket/socket"
          "/var/lib/hydra/build-logs/"
        ];
        ReadOnlyPaths = [ "/nix/" ];
        RuntimeDirectory = "queue-runner";

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        PrivateMounts = true;
        RemoveIPC = true;
        UMask = "0022";

        CapabilityBoundingSet = "";
        NoNewPrivileges = true;

        ProtectKernelModules = true;
        SystemCallArchitectures = "native";
        ProtectKernelLogs = true;
        ProtectClock = true;

        RestrictAddressFamilies = "";

        LockPersonality = true;
        ProtectHostname = true;
        RestrictRealtime = true;
        MemoryDenyWriteExecute = true;
        PrivateUsers = true;
        RestrictNamespaces = true;
      };
    };

    environment.etc."hydra/queue-runner.toml".source = format.generate "queue-runner.toml" (
      lib.filterAttrsRecursive (_: v: v != null) cfg.settings
    );
    systemd.tmpfiles.rules = [
      "d /nix/var/nix/gcroots/per-user/hydra-queue-runner 0755 hydra-queue-runner hydra -"
      "d /var/lib/hydra/build-logs/ 0755 hydra-queue-runner hydra -"
    ];

    users = {
      groups.hydra = { };
      users.hydra-queue-runner = {
        group = "hydra";
        isSystemUser = true;
      };
    };
  };
}

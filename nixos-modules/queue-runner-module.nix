{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.hydra-queue-runner-dev;

  user = "hydra-queue-runner";

  format = pkgs.formats.toml { };
in
{
  options = {
    services.hydra-queue-runner-dev = {
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
                "WithCriticalPath"
              ];
              default = "WithRdeps";
            };
            dispatchTriggerTimerInS = lib.mkOption {
              description = "Timer for triggering dispatch in an interval in seconds. Setting this to a value <= 0 will disable this timer and only trigger the dispatcher if queue changes happened.";
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
              description = "Seconds after which the queue run should be interrupted early. Setting this to a value <= 0 will disable this feature and the queue run will never exit early.";
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
            tokenPaths = lib.mkOption {
              description = "List of paths of allowed authentication tokens.";
              type = lib.types.nullOr (lib.types.listOf lib.types.path);
              default = null;
            };
            enableFodChecker = lib.mkOption {
              description = "This will enable the FOD checker. It will collect FOD in a separate queue and schedule these builds to a separate machine with the mandatory feature FOD.";
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
            overflowStore = lib.mkOption {
              description = "Overflow S3 store. Steps referenced only by the listed jobsets are uploaded there instead of the default store. Requires usePresignedUploads.";
              default = null;
              type = lib.types.nullOr (
                lib.types.submodule {
                  options = {
                    store = lib.mkOption {
                      description = "S3 store URI of the overflow bucket, e.g. `s3://overflow?region=eu-west-1`.";
                      type = lib.types.singleLineStr;
                    };
                    jobsets = lib.mkOption {
                      description = "Jobsets (`project:jobset`) whose exclusive steps go to the overflow store.";
                      type = lib.types.listOf lib.types.singleLineStr;
                      default = [ ];
                    };
                  };
                }
              );
            };
            forcedSubstituters = lib.mkOption {
              description = "Force a list of substituters per builder. Builder will no longer be accepted if they don't have `useSubstitutes` with the substituters listed here.";
              type = lib.types.listOf lib.types.singleLineStr;
              default = [ ];
            };
            maxOutputSize = lib.mkOption {
              description = "Per-output NAR size limit in bytes. Builds whose output exceeds this fail with NarSizeLimitExceeded. 0 disables the check.";
              type = lib.types.ints.unsigned;
              default = 0;
            };
            maxSilentTime = lib.mkOption {
              description = "Default maximum silent time in seconds for builds without meta.maxSilent. Also used as a floor for dependency-only steps.";
              type = lib.types.ints.unsigned;
              default = 3600;
            };
            buildTimeout = lib.mkOption {
              description = "Default build timeout in seconds for builds without meta.timeout. Also used as a floor for dependency-only steps.";
              type = lib.types.ints.unsigned;
              default = 36000;
            };
            maxLogSize = lib.mkOption {
              description = "Maximum build log size in bytes before a build fails with LogLimitExceeded.";
              type = lib.types.ints.unsigned;
              default = 64 * 1024 * 1024;
            };
          };
        };
        default = { };
      };

      grpc = lib.mkOption {
        description = "gRPC listener options";
        default = { };
        type = lib.types.submodule {
          options = {
            address = lib.mkOption {
              type = lib.types.singleLineStr;
              default = "[::1]";
              description = "The IP address the gRPC listener should bind to.";
            };

            port = lib.mkOption {
              description = "Which gRPC port this app should listen on.";
              type = lib.types.port;
              default = 50051;
            };
          };
        };
      };

      rest = lib.mkOption {
        description = "REST listener options";
        default = { };
        type = lib.types.submodule {
          options = {
            address = lib.mkOption {
              type = lib.types.singleLineStr;
              default = "[::1]";
              description = "The IP address the REST listener should bind to.";
            };

            port = lib.mkOption {
              description = "Which REST port this app should listen on.";
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

      minimumDiskFree = lib.mkOption {
        type = lib.types.int;
        default = 0;
        description = ''
          Threshold of minimum disk space (GiB) to determine if the queue runner should run or not.
        '';
      };

      awsCredentialsFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to an AWS credentials file. When set, the
          `AWS_SHARED_CREDENTIALS_FILE` environment variable is passed to the
          queue runner so that the AWS SDK finds credentials without relying
          on the EC2 instance metadata service (IMDS).
        '';
      };

      otel = lib.mkOption {
        description = "OpenTelemetry (OTLP) tracing options.";
        default = { };
        type = lib.types.submodule {
          options = {
            enable = lib.mkEnableOption ''
              OpenTelemetry tracing. Builds the queue runner with the `otel`
              cargo feature and exports spans via OTLP/gRPC, configured
              through the standard `OTEL_*` environment variables
            '';

            endpoint = lib.mkOption {
              description = "OTLP collector endpoint (`OTEL_EXPORTER_OTLP_ENDPOINT`). The exporter uses gRPC, so point at the gRPC port (typically 4317).";
              type = lib.types.nullOr lib.types.singleLineStr;
              default = null;
              example = "http://127.0.0.1:4317";
            };

            protocol = lib.mkOption {
              description = "OTLP protocol (`OTEL_EXPORTER_OTLP_PROTOCOL`).";
              type = lib.types.nullOr (
                lib.types.enum [
                  "grpc"
                  "http/protobuf"
                  "http/json"
                ]
              );
              default = null;
            };

            headers = lib.mkOption {
              description = "Headers sent to the collector (`OTEL_EXPORTER_OTLP_HEADERS`). Ends up in the world-readable systemd unit, so do not put secrets here.";
              type = lib.types.nullOr lib.types.singleLineStr;
              default = null;
              example = "authorization=Bearer token";
            };

            serviceName = lib.mkOption {
              description = "Service name reported to the collector (`OTEL_SERVICE_NAME`). Defaults to the binary name (`hydra-queue-runner`).";
              type = lib.types.nullOr lib.types.singleLineStr;
              default = null;
            };

            extraEnv = lib.mkOption {
              description = "Additional `OTEL_*` environment variables not exposed as dedicated options.";
              type = lib.types.attrsOf lib.types.singleLineStr;
              default = { };
              example = {
                OTEL_TRACES_SAMPLER = "parentbased_traceidratio";
                OTEL_TRACES_SAMPLER_ARG = "0.1";
              };
            };
          };
        };
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./. { withOtel = cfg.otel.enable; };
        defaultText = lib.literalExpression "pkgs.callPackage ./. { withOtel = cfg.otel.enable; }";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.hydra-queue-runner-dev = {
      description = "Hydra Queue Runner main service";

      requires = [
        "nix-daemon.socket"
        "hydra-queue-runner-dev-rest.socket"
        "hydra-queue-runner-dev-grpc.socket"
      ];
      after = [
        # sets up database, queue-runner crashes if schema is incorrect
        "hydra-init.service"
        # queue-runner may need to connect to another machine
        "network.target"
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
        HOME = "/run/hydra-queue-runner";
      }
      // lib.optionalAttrs (cfg.awsCredentialsFile != null) {
        AWS_SHARED_CREDENTIALS_FILE = cfg.awsCredentialsFile;
      }
      // lib.optionalAttrs cfg.otel.enable (
        lib.filterAttrs (_: v: v != null) {
          OTEL_EXPORTER_OTLP_ENDPOINT = cfg.otel.endpoint;
          OTEL_EXPORTER_OTLP_PROTOCOL = cfg.otel.protocol;
          OTEL_EXPORTER_OTLP_HEADERS = cfg.otel.headers;
          OTEL_SERVICE_NAME = cfg.otel.serviceName;
        }
        // cfg.otel.extraEnv
      );

      serviceConfig = {
        Type = "notify";
        Restart = "always";
        RestartSec = "5s";
        # The runner holds a gRPC stream per builder plus DB pool and HTTP
        # connections; the default 1024 soft limit is easily exhausted.
        LimitNOFILE = 65536;

        ExecStart = lib.escapeShellArgs (
          [
            "${cfg.package}/bin/hydra-queue-runner"
            "--rest-bind"
            "-"
            "--grpc-bind"
            "-"
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

        User = user;
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
          "/nix/var/nix/daemon-socket/socket"
          "/var/lib/hydra/build-logs/"
        ]
        ++ lib.optionals (lib.hasInfix "%2Frun%2Fpostgresql" cfg.settings.dbUrl) [
          "/run/postgresql/.s.PGSQL.${toString config.services.postgresql.settings.port}"
        ];
        ReadOnlyPaths = [ "/nix/" ];
        RuntimeDirectory = "hydra-queue-runner";

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

    systemd.sockets.hydra-queue-runner-dev-rest = {
      description = "Hydra Queue Runner REST socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "${cfg.rest.address}:${toString cfg.rest.port}";
        FileDescriptorName = "rest";
        Service = "hydra-queue-runner-dev.service";
      };
    };

    systemd.sockets.hydra-queue-runner-dev-grpc = {
      description = "Hydra Queue Runner gRPC socket";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = "${cfg.grpc.address}:${toString cfg.grpc.port}";
        FileDescriptorName = "grpc";
        Service = "hydra-queue-runner-dev.service";
      };
    };

    # If there is less than a certain amount of free disk space, stop
    # the queue to prevent builds from failing or aborting.
    # Leaves a tag file indicating this reason; if the tag file exists
    # and disk space is above the threshold + 10GB, the queue will be
    # restarted; starting it if it is already started is not harmful.
    systemd.services.hydra-queue-runner-check-space = {
      script = ''
        ${builtins.readFile ./check-space.sh}
        spacestopstart hydra-queue-runner-dev ${toString cfg.minimumDiskFree}
      '';
      startAt = "*:0/5";
    };

    environment.etc."hydra/queue-runner.toml".source = format.generate "queue-runner.toml" (
      lib.filterAttrsRecursive (_: v: v != null) cfg.settings
    );
    systemd.tmpfiles.rules = [
      "d /nix/var/nix/gcroots/per-user/${user} 0755 ${user} hydra -"
      "d /var/lib/hydra/build-logs/ 0755 hydra-queue-runner hydra -"
      "d /var/lib/hydra/queue-runner 0700 hydra-queue-runner hydra -"
    ];

    services.postgresql.identMap = ''
      hydra-users ${user} hydra
    '';

    nix.settings = {
      trusted-users = [ user ];
    };

    users = {
      groups.hydra = { };
      users.${user} = {
        group = "hydra";
        isSystemUser = true;
        home = "/var/lib/hydra/queue-runner";
      };
    };
  };
}

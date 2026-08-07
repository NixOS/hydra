{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.hydra-queue-builder-dev;
  user = "hydra-queue-builder";

  suffix = name: lib.optionalString (name != "default") "-${name}";

  mkService = name: icfg: {
    description = "Hydra Queue Builder main service${
      lib.optionalString (name != "default") " (${name})"
    }";

    requires = [ "nix-daemon.socket" ];
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      NIX_REMOTE = "daemon";
      LIBEV_FLAGS = "4"; # go ahead and mandate epoll(2)
      RUST_BACKTRACE = "1";

      # Note: it's important to set this for nix-store, because it wants to use
      # $HOME in order to use a temporary cache dir. bizarre failures will occur
      # otherwise
      HOME = "/run/hydra-queue-builder${suffix name}";
    };

    path = [ config.nix.package ];

    serviceConfig = {
      Type = "notify";
      Restart = "always";
      RestartSec = "5s";

      ExecStart = lib.escapeShellArgs (
        [
          "${icfg.package}/bin/hydra-builder"
          "--gateway-endpoint"
          icfg.queueRunnerAddr
          "--ping-interval"
          cfg.pingInterval
          "--speed-factor"
          cfg.speedFactor
          "--max-jobs"
          icfg.maxJobs
          "--build-dir-avail-threshold"
          cfg.buildDirAvailThreshold
          "--store-avail-threshold"
          cfg.storeAvailThreshold
          "--load1-threshold"
          cfg.load1Threshold
          "--cpu-psi-threshold"
          cfg.cpuPsiThreshold
          "--mem-psi-threshold"
          cfg.memPsiThreshold
        ]
        ++ lib.optionals (cfg.ioPsiThreshold != null) [
          "--io-psi-threshold"
          cfg.ioPsiThreshold
        ]
        ++ (builtins.concatMap (v: [
          "--systems"
          v
        ]) cfg.systems)
        ++ (builtins.concatMap (v: [
          "--supported-features"
          v
        ]) cfg.supportedFeatures)
        ++ (builtins.concatMap (v: [
          "--mandatory-features"
          v
        ]) cfg.mandatoryFeatures)
        ++ lib.optionals (cfg.useSubstitutes != null) [
          "--use-substitutes"
        ]
        ++ lib.optionals (icfg.authorizationFile != null) [
          "--authorization-file"
          icfg.authorizationFile
        ]
        ++ lib.optionals (icfg.mtls != null) [
          "--server-root-ca-cert-path"
          icfg.mtls.serverRootCaCertPath
          "--client-cert-path"
          icfg.mtls.clientCertPath
          "--client-key-path"
          icfg.mtls.clientKeyPath
          "--domain-name"
          icfg.mtls.domainName
        ]
      );

      User = user;
      Group = "hydra";

      PrivateNetwork = false;
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
        "~@resources"
      ];

      ReadWritePaths = [
        "/nix/var/nix/gcroots/"
        "/nix/var/nix/daemon-socket/socket"
      ];
      ReadOnlyPaths = [ "/nix/" ];
      RuntimeDirectory = "hydra-queue-builder${suffix name}";

      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      PrivateMounts = true;
      RemoveIPC = true;
      UMask = "0077";

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
in
{
  options = {
    services.hydra-queue-builder-dev = {
      enable = lib.mkEnableOption "QueueBuilder";

      queueRunnerAddr = lib.mkOption {
        description = "Queue Runner address to the grpc server";
        type = lib.types.singleLineStr;
      };

      pingInterval = lib.mkOption {
        description = "Interval in which pings are send to the runner";
        type = lib.types.ints.positive;
        default = 10;
      };

      speedFactor = lib.mkOption {
        description = "Additional Speed factor for this machine";
        type = lib.types.oneOf [
          lib.types.ints.positive
          lib.types.float
        ];
        default = 1;
      };

      maxJobs = lib.mkOption {
        description = "Maximum allowed of jobs. This only is used if the queue runner uses this metrics for determining free machines.";
        type = lib.types.ints.positive;
        default = 4;
      };

      buildDirAvailThreshold = lib.mkOption {
        description = "Threshold in percent for nix build dir before jobs are no longer scheduled on the machine";
        type = lib.types.float;
        default = 10.0;
      };

      storeAvailThreshold = lib.mkOption {
        description = "Threshold in percent for /nix/store before jobs are no longer scheduled on the machine";
        type = lib.types.float;
        default = 10.0;
      };

      load1Threshold = lib.mkOption {
        description = "Maximum Load1 threshold before we stop scheduling jobs on that node. Only used if PSI is not available.";
        type = lib.types.float;
        default = 8.0;
      };

      cpuPsiThreshold = lib.mkOption {
        description = "Maximum CPU PSI in the last 10s before we stop scheduling jobs on that node";
        type = lib.types.float;
        default = 75.0;
      };

      memPsiThreshold = lib.mkOption {
        description = "Maximum Memory PSI in the last 10s before we stop scheduling jobs on that node";
        type = lib.types.float;
        default = 80.0;
      };

      ioPsiThreshold = lib.mkOption {
        description = "Maximum IO PSI in the last 10s before we stop scheduling jobs on that node. If null then this pressure check is disabled.";
        type = lib.types.nullOr lib.types.float;
        default = null;
      };

      systems = lib.mkOption {
        description = "List of supported systems. If none are passed, system and extra-platforms are read from nix.";
        type = lib.types.listOf lib.types.singleLineStr;
        default = [ ];
      };

      supportedFeatures = lib.mkOption {
        description = "Pass supported features to the builder. If none are passed, system features will be used.";
        type = lib.types.listOf lib.types.singleLineStr;
        default = [ ];
      };

      mandatoryFeatures = lib.mkOption {
        description = "Pass mandatory features to the builder.";
        type = lib.types.listOf lib.types.singleLineStr;
        default = [ ];
      };

      useSubstitutes = lib.mkOption {
        description = "Use substitution for paths";
        type = lib.types.bool;
        default = true;
      };

      authorizationFile = lib.mkOption {
        description = "Path to token authorization file if token auth should be used.";
        type = lib.types.nullOr lib.types.path;
        default = null;
      };

      mtls = lib.mkOption {
        description = "mtls options";
        default = null;
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              serverRootCaCertPath = lib.mkOption {
                description = "Server root ca certificate path";
                type = lib.types.path;
              };
              clientCertPath = lib.mkOption {
                description = "Client certificate path";
                type = lib.types.path;
              };
              clientKeyPath = lib.mkOption {
                description = "Client key path";
                type = lib.types.path;
              };
              domainName = lib.mkOption {
                description = "Domain name for mtls";
                type = lib.types.singleLineStr;
              };
            };
          }
        );
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./. { };
      };

      instances = lib.mkOption {
        description = ''
          Additional queue builders, one per further queue runner this machine
          serves. ofborg runs its own Hydra alongside the staging one.

          Each entry gets a `hydra-queue-builder-dev-<name>` unit next to the
          one the options above configure, which is left untouched. Anything an
          instance does not set falls back to the value above it, since those
          describe the machine rather than the queue runner it talks to.

          Instances do not know about each other, so their `maxJobs` add up.

          All instances run the same binary by default. That matters: the queue
          runner rejects a builder whose `PROTO_API_VERSION` differs from its
          own, so serving two runners built from different trees needs a
          per-instance `package`.
        '';
        default = { };
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              queueRunnerAddr = lib.mkOption {
                description = "Queue Runner address to the grpc server";
                type = lib.types.singleLineStr;
              };

              maxJobs = lib.mkOption {
                description = "Maximum allowed of jobs for this instance.";
                type = lib.types.ints.positive;
                default = cfg.maxJobs;
                defaultText = lib.literalExpression "config.services.hydra-queue-builder-dev.maxJobs";
              };

              authorizationFile = lib.mkOption {
                description = "Path to token authorization file if token auth should be used.";
                type = lib.types.nullOr lib.types.path;
                default = cfg.authorizationFile;
                defaultText = lib.literalExpression "config.services.hydra-queue-builder-dev.authorizationFile";
              };

              mtls = lib.mkOption {
                description = "mtls options";
                type = lib.types.nullOr (
                  lib.types.submodule {
                    options = {
                      serverRootCaCertPath = lib.mkOption {
                        description = "Server root ca certificate path";
                        type = lib.types.path;
                      };
                      clientCertPath = lib.mkOption {
                        description = "Client certificate path";
                        type = lib.types.path;
                      };
                      clientKeyPath = lib.mkOption {
                        description = "Client key path";
                        type = lib.types.path;
                      };
                      domainName = lib.mkOption {
                        description = "Domain name for mtls";
                        type = lib.types.singleLineStr;
                      };
                    };
                  }
                );
                default = cfg.mtls;
                defaultText = lib.literalExpression "config.services.hydra-queue-builder-dev.mtls";
              };

              package = lib.mkOption {
                type = lib.types.package;
                default = cfg.package;
                defaultText = lib.literalExpression "config.services.hydra-queue-builder-dev.package";
              };
            };
          }
        );
      };
    };
  };

  config = lib.mkIf (cfg.enable || cfg.instances != { }) {
    assertions = [
      {
        assertion = !(cfg.enable && cfg.instances ? default);
        message = ''
          services.hydra-queue-builder-dev: `enable` and `instances.default` both
          configure the `hydra-queue-builder-dev` unit. Use one or the other.
        '';
      }
    ];

    systemd.services =
      # The options outside `instances` keep driving the historically named
      # unit, so existing configurations are unaffected.
      lib.optionalAttrs cfg.enable { hydra-queue-builder-dev = mkService "default" cfg; }
      // lib.mapAttrs' (
        name: icfg: lib.nameValuePair "hydra-queue-builder-dev${suffix name}" (mkService name icfg)
      ) cfg.instances;

    systemd.tmpfiles.rules = [
      "d /nix/var/nix/gcroots/per-user/${user} 0755 ${user} hydra -"
    ];

    nix = {
      settings = {
        trusted-users = [ user ];
        experimental-features = [ "nix-command" ];
      };
    };

    users = {
      groups.hydra = { };
      users.${user} = {
        group = "hydra";
        isSystemUser = true;
      };
    };

  };
}

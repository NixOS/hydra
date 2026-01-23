{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.queue-builder-dev;
in
{
  options = {
    services.queue-builder-dev = {
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
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.queue-builder-dev = {
      description = "queue-builder main service";

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
        HOME = "/run/queue-builder";
      };

      serviceConfig = {
        Type = "notify";
        Restart = "always";
        RestartSec = "5s";

        ExecStart = lib.escapeShellArgs (
          [
            "${cfg.package}/bin/builder"
            "--gateway-endpoint"
            cfg.queueRunnerAddr
            "--ping-interval"
            cfg.pingInterval
            "--speed-factor"
            cfg.speedFactor
            "--max-jobs"
            cfg.maxJobs
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
          ++ lib.optionals (cfg.authorizationFile != null) [
            "--authorization-file"
            cfg.authorizationFile
          ]
          ++ lib.optionals (cfg.mtls != null) [
            "--server-root-ca-cert-path"
            cfg.mtls.serverRootCaCertPath
            "--client-cert-path"
            cfg.mtls.clientCertPath
            "--client-key-path"
            cfg.mtls.clientKeyPath
            "--domain-name"
            cfg.mtls.domainName
          ]
        );

        User = "hydra-queue-builder";
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
        RuntimeDirectory = "queue-builder";

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

    systemd.tmpfiles.rules = [
      "d /nix/var/nix/gcroots/per-user/hydra-queue-builder 0755 hydra-queue-builder hydra -"
    ];
    nix = {
      settings = {
        allowed-users = [ "hydra-queue-builder" ];
        trusted-users = [ "hydra-queue-builder" ];
        experimental-features = [ "nix-command" ];
      };
    };

    users = {
      groups.hydra = { };
      users.hydra-queue-builder = {
        group = "hydra";
        isSystemUser = true;
      };
    };

  };
}

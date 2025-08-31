{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.queue-builder-dev;
  user = config.users.users.hydra-queue-builder;
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

      tmpAvailThreshold = lib.mkOption {
        description = "Threshold in percent for /tmp before jobs are no longer scheduled on the machine";
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

      logFile = lib.mkOption {
        type = lib.types.path;
        default = "/var/log/hydra-queue-builder.log";
        description = "The logfile to use for the hydra-queue-builder service.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    launchd.daemons.queue-builder-dev = {
      script = ''
        exec ${
          lib.escapeShellArgs (
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
              "--tmp-avail-threshold"
              cfg.tmpAvailThreshold
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
          )
        }
      '';

      environment = {
        RUST_BACKTRACE = "1";
        NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      };

      serviceConfig = {
        KeepAlive = true;
        StandardErrorPath = cfg.logFile;
        StandardOutPath = cfg.logFile;

        GroupName = "hydra";
        UserName = "hydra-queue-builder";
        WorkingDirectory = user.home;
      };
    };
    users = {
      users.hydra-queue-builder = {
        uid = lib.mkDefault 535;
        gid = lib.mkDefault config.users.groups.hydra.gid;
        home = lib.mkDefault "/var/lib/hydra-queue-builder";
        shell = "/bin/bash";
        description = "hydra-queue-builder service user";
      };
      knownUsers = [ "hydra-queue-builder" ];
      groups.hydra = {
        gid = lib.mkDefault 535;
        description = "Nix group for hydra-queue-builder service";
      };
      knownGroups = [ "hydra" ];
    };

    # FIXME: create logfiles automatically if defined.
    system.activationScripts.preActivation.text = ''
      mkdir -p '${user.home}'
      touch '${cfg.logFile}'
      chown ${toString user.uid}:${toString user.gid} '${user.home}' '${cfg.logFile}'

      # create gcroots
      mkdir -p /nix/var/nix/gcroots/per-user/hydra-queue-builder
      chown ${toString user.uid}:${toString user.gid} /nix/var/nix/gcroots/per-user/hydra-queue-builder
      chmod 0755 /nix/var/nix/gcroots/per-user/hydra-queue-builder
    '';
  };
}

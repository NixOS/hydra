{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.hydra-drv-daemon-dev;
  user = "hydra-queue-runner";
in
{
  options.services.hydra-drv-daemon-dev = {
    enable = lib.mkEnableOption "Hydra drv-daemon (turns IFD / imperative builds into ad-hoc Hydra Builds)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ../subprojects/hydra-drv-daemon/package.nix { };
    };

    socketPath = lib.mkOption {
      type = lib.types.path;
      default = "/run/hydra-drv-daemon/socket";
      description = ''
        Socket path used by clients (e.g. hydra-evaluator, imperative `nix-store --realise`) to reach the daemon.
      '';
    };

    upstreamSocket = lib.mkOption {
      type = lib.types.path;
      default = "/nix/var/nix/daemon-socket/socket";
      description = ''
        Upstream nix-daemon socket that the drv-daemon proxies read
        ops and `.drv` uploads to.
      '';
    };

    dbUrl = lib.mkOption {
      type = lib.types.singleLineStr;
      default = "postgres://hydra@%2Frun%2Fpostgresql:5432/hydra";
      description = "PostgreSQL connection URL.";
    };
  };

  config = lib.mkIf cfg.enable {
    # The queue-runner module creates the shared user and PostgreSQL ident mapping.
    assertions = [
      {
        assertion = config.services.hydra-queue-runner-dev.enable;
        message = ''
          services.hydra-drv-daemon-dev.enable requires
          services.hydra-queue-runner-dev.enable, because the daemon
          shares the queue-runner's "hydra-queue-runner" user/group
          and ident-map setup.
        '';
      }
    ];

    systemd.services.hydra-drv-daemon = {
      description = "Hydra drv-daemon (ad-hoc Build dispatcher)";

      after = [
        "hydra-init.service"
        "nix-daemon.socket"
        "network.target"
      ];
      requires = [ "hydra-init.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        RUST_BACKTRACE = "1";
        HYDRA_DBA = cfg.dbUrl;
      };

      serviceConfig = {
        Restart = "always";
        RestartSec = "5s";

        ExecStart = lib.escapeShellArgs [
          "${cfg.package}/bin/hydra-drv-daemon"
          "--socket"
          cfg.socketPath
          "--upstream-socket"
          cfg.upstreamSocket
        ];

        User = user;
        Group = "hydra";

        RuntimeDirectory = "hydra-drv-daemon";
        RuntimeDirectoryMode = "0755";

        ReadWritePaths = [
          "/run/postgresql/.s.PGSQL.${toString config.services.postgresql.settings.port}"
          cfg.upstreamSocket
        ];
        ReadOnlyPaths = [ "/nix/" ];

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        RemoveIPC = true;
        LockPersonality = true;
        NoNewPrivileges = true;
        UMask = "0022";
        CapabilityBoundingSet = "";
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
      };
    };
  };
}

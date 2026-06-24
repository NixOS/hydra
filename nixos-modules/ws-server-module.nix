{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.hydra-ws-dev;

  user = "hydra-ws";

  format = pkgs.formats.toml { };
in
{
  options = {
    services.hydra-ws-dev = {
      enable = lib.mkEnableOption "WebSocket Listener";

      settings = lib.mkOption {
        description = "Reloadable settings for queue runner";
        type = lib.types.submodule {
          options = {
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
            idleGrace = lib.mkOption {
              description = "Idle grace period in seconds before stopping a tail";
              type = lib.types.int;
              default = 128;
            };
            hydraDataDir = lib.mkOption {
              description = "Hydra data directory";
              type = lib.types.path;
              default = "/var/lib/hydra";
            };
          };
        };
        default = { };
      };

      bind = lib.mkOption {
        description = "WebSocket listener options";
        default = { };
        type = lib.types.submodule {
          options = {
            address = lib.mkOption {
              type = lib.types.singleLineStr;
              default = "[::1]";
              description = "The IP address the WS listener should bind to.";
            };

            port = lib.mkOption {
              description = "Which WS port this app should listen on.";
              type = lib.types.port;
              default = 9283;
            };
          };
        };
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.callPackage ./. { };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.hydra-ws-dev = {
      description = "Hydra WebSocket service";

      requires = [
        "nix-daemon.socket"
      ];
      after = [
        "hydra-init.service"
        "network.target"
      ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "5s";

        ExecStart = lib.escapeShellArgs [
          "${cfg.package}/bin/hydra-ws"
          "--bind"
          "${cfg.bind.address}:${toString cfg.bind.port}"
          "--config-path"
          "${format.generate "hydra-ws.toml" (lib.filterAttrsRecursive (_: v: v != null) cfg.settings)}"
        ];

        User = user;
        Group = "hydra";

        PrivateNetwork = false;
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        ReadWritePaths = [
          "/var/lib/hydra/build-logs/"
        ]
        ++ lib.optionals (lib.hasInfix "%2Frun%2Fpostgresql" cfg.settings.dbUrl) [
          "/run/postgresql/.s.PGSQL.${toString config.services.postgresql.settings.port}"
        ];
        RuntimeDirectory = "hydra-ws";

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

    systemd.tmpfiles.rules = [
      "d /var/lib/hydra/build-logs/ 0755 hydra-ws hydra -"
    ];

    services.postgresql.identMap = ''
      hydra-users ${user} hydra
    '';

    users = {
      groups.hydra = { };
      users.${user} = {
        group = "hydra";
        isSystemUser = true;
      };
    };
  };
}

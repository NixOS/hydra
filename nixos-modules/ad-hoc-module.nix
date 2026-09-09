{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.hydra-ad-hoc-dev;

  user = "hydra-ad-hoc";
  # Owns the socket file, so membership is what admits a client. Not
  # `hydra`: that group is Hydra's own services, and who may submit
  # builds from outside is a separate question.
  clientGroup = "hydra-ad-hoc";

  format = pkgs.formats.toml { };

  otel = import ./otel.nix { inherit lib; };
in
{
  options = {
    services.hydra-ad-hoc-dev = {
      enable = lib.mkEnableOption "hydra-ad-hoc, an optional and still experimental service that presents Hydra as one giant nix daemon: ad hoc jobs and ad hoc store usage become Hydra Builds";

      settings = lib.mkOption {
        description = ''
          Settings for hydra-ad-hoc, written to
          `/etc/hydra/ad-hoc.toml`.

          Every service in Rust in hydra has its own separate TOML configuration file,
          with just the settings it needs.
        '';
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
              default = 4;
            };
            upstreamSocket = lib.mkOption {
              description = ''
                Upstream nix-daemon socket that hydra-ad-hoc proxies read
                ops and `.drv` uploads to.
              '';
              type = lib.types.path;
              default = "/nix/var/nix/daemon-socket/socket";
            };
            storeDir = lib.mkOption {
              description = "Nix store directory.";
              type = lib.types.path;
              default = "/nix/store";
            };
            hydraDataDir = lib.mkOption {
              description = "Hydra data directory; build-step logs are streamed to clients from its `build-logs`.";
              type = lib.types.path;
              default = "/var/lib/hydra";
            };
          };
        };
        default = { };
      };

      socketPath = lib.mkOption {
        type = lib.types.path;
        default = "/run/hydra-ad-hoc/socket";
        description = ''
          Socket path used by clients to reach the daemon.
        '';
      };

      otel = otel.mkOtelOption {
        component = "hydra-ad-hoc";
        binary = "hydra-ad-hoc";
      };

      package = lib.mkOption {
        type = lib.types.package;
        # `withOtel` is a knob on the rust workspace, not on this crate: cargo
        # resolves features once for the whole workspace build.
        default = (pkgs.hydraComponents.overrideScope (_: _: { withOtel = cfg.otel.enable; })).hydra-ad-hoc;
        defaultText = lib.literalExpression "pkgs.hydraComponents.hydra-ad-hoc";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.hydra-ad-hoc-dev = {
      description = "Hydra ad-hoc Build dispatcher (experimental)";

      requires = [
        "nix-daemon.socket"
        "hydra-ad-hoc-dev.socket"
      ];
      after = [
        # sets up database
        "hydra-init.service"
        "network.target"
      ];
      wantedBy = [ "multi-user.target" ];
      # The daemon has no hot-reload; restart it when the config changes.
      restartTriggers = [ config.environment.etc."hydra/ad-hoc.toml".source ];

      environment = {
        RUST_BACKTRACE = "1";
      }
      // otel.otelEnv cfg.otel;

      serviceConfig = {
        Type = "notify";
        Restart = "always";
        RestartSec = "5s";

        ExecStart = lib.escapeShellArgs [
          "${cfg.package}/bin/hydra-ad-hoc"
          "--socket"
          "-"
          "--config-path"
          "/etc/hydra/ad-hoc.toml"
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
          cfg.settings.upstreamSocket
        ]
        ++ lib.optionals (lib.hasInfix "%2Frun%2Fpostgresql" cfg.settings.dbUrl) [
          "/run/postgresql/.s.PGSQL.${toString config.services.postgresql.settings.port}"
        ];
        ReadOnlyPaths = [
          "/nix/"
          # Live logs for waiting clients come from the queue runner's files.
          "${cfg.settings.hydraDataDir}/build-logs/"
        ];

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

    # systemd owns the socket file: it creates the parent directory,
    # and the group and mode below are what limit build submission to
    # members of `clientGroup` rather than every local user.
    systemd.sockets.hydra-ad-hoc-dev = {
      description = "Hydra ad-hoc Build dispatcher socket (experimental)";
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        ListenStream = cfg.socketPath;
        SocketUser = user;
        SocketGroup = clientGroup;
        SocketMode = "0660";
        FileDescriptorName = "daemon";
        Service = "hydra-ad-hoc-dev.service";
      };
    };

    environment.etc."hydra/ad-hoc.toml".source = format.generate "ad-hoc.toml" (
      lib.filterAttrsRecursive (_: v: v != null) cfg.settings
    );

    services.postgresql.identMap = ''
      hydra-users ${user} hydra
    '';

    # Same trust as the queue-runner: the daemon talks to the upstream
    # nix-daemon on behalf of its clients, and some of what it forwards
    # may need a trusted user.
    nix.settings = {
      trusted-users = [ user ];
    };

    users = {
      groups.hydra = { };
      # Clients, not the daemon: it runs as `hydra` like the other services.
      groups.${clientGroup} = { };
      users.${user} = {
        group = "hydra";
        isSystemUser = true;
      };
    };
  };
}

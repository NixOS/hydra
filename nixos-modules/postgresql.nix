{ config, pkgs, lib, ... }:

let

  cfg = config.services.hydra-dev;

  baseDir = "/var/lib/hydra";

  localDB = "dbi:Pg:dbname=hydra;user=hydra;";

  haveLocalDB = cfg.dbi == localDB;

in

{
  config = lib.mkIf cfg.enable {

    systemd.tmpfiles.rules = [
      "d ${baseDir} 0750 hydra hydra"
      "d ${cfg.gcRootsDir} 2775 hydra hydra"
    ];

    users.groups.hydra = { };

    users.users.hydra =
      { description = "Hydra";
        group = "hydra";
        home = baseDir;
        isSystemUser = true;
        useDefaultShell = true;
      };

    nix.settings = {
      keep-outputs = true;
      keep-derivations = true;
    };

    systemd.services.hydra-init =
      { wantedBy = [ "multi-user.target" ];

        after = lib.mkIf haveLocalDB [
          # user won't exist until setup is done
          "postgresql-setup.service"
          # hydra-init accesses postgres
          "postgresql.service"
        ];
        environment = {
          HYDRA_DBI = "${cfg.dbi};application_name=hydra-init";
          HYDRA_CONFIG = "${baseDir}/hydra.conf";
          HYDRA_DATA = baseDir;
          PGPASSFILE = "${baseDir}/pgpass";
        };
        path = [ pkgs.util-linux ];
        preStart = ''
          ${lib.optionalString haveLocalDB ''
            echo "create extension if not exists pg_trgm" | runuser -u ${config.services.postgresql.superUser} -- ${config.services.postgresql.package}/bin/psql hydra
          ''}

          if [ ! -e ${cfg.gcRootsDir} ]; then
            # Move legacy roots directory.
            if [ -e /nix/var/nix/gcroots/per-user/hydra/hydra-roots ]; then
              mv /nix/var/nix/gcroots/per-user/hydra/hydra-roots ${cfg.gcRootsDir}
            fi
          fi

          # Move legacy hydra-www roots.
          if [ -e /nix/var/nix/gcroots/per-user/hydra-www/hydra-roots ]; then
            find /nix/var/nix/gcroots/per-user/hydra-www/hydra-roots/ -type f \
              | xargs -r mv -f -t ${cfg.gcRootsDir}/
            rmdir /nix/var/nix/gcroots/per-user/hydra-www/hydra-roots
          fi
        '';
        serviceConfig = {
          ExecStart = "${cfg.package}/bin/hydra-init";
          PermissionsStartOnly = true;
          User = "hydra";
          Type = "oneshot";
          RemainAfterExit = true;
        };
      };

    services.postgresql = lib.mkIf haveLocalDB {
      enable = true;
      ensureDatabases = [ "hydra" ];
      ensureUsers = [
        {
          name = "hydra";
          ensureDBOwnership = true;
        }
      ];
      identMap = ''
          hydra-users hydra hydra
          hydra-users root hydra
          # The postgres user is used to create the pg_trgm extension for the hydra database
          hydra-users postgres postgres
        '';

      authentication = ''
          local hydra all ident map=hydra-users
        '';
    };
  };
}

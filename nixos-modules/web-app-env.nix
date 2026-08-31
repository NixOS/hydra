# What a service needs to share the web app's configuration: the database,
# `hydra.conf`, and the data directory. The web app's own services use this,
# and so does any other module whose service runs Hydra's Perl, which reads
# all three.
{
  lib,
  cfg,
}:

with lib;

rec {
  baseDir = "/var/lib/hydra";

  hydraEnv = {
    HYDRA_DATABASE_URL = cfg.dbUrl;
    HYDRA_CONFIG = "${baseDir}/hydra.conf";
    HYDRA_DATA = "${baseDir}";
  };

  # The database URL with an `application_name` query parameter added, to
  # distinguish where queries come from in Postgres statistics.
  #
  # `%` is doubled because these end up in systemd `Environment=`, where a
  # bare `%` starts a specifier: the percent-encoded socket directory in the
  # default URL (`%2Frun%2Fpostgresql`) otherwise makes systemd drop the
  # whole assignment as an invalid specifier, and the services silently fall
  # back to connecting as their own Unix user.
  dbUrlWithAppName =
    name:
    replaceStrings [ "%" ] [ "%%" ] (
      "${cfg.dbUrl}${if hasInfix "?" cfg.dbUrl then "&" else "?"}application_name=${name}"
    );

  env = {
    NIX_REMOTE = "daemon";
    PGPASSFILE = "${baseDir}/pgpass";
  }
  // hydraEnv
  // cfg.extraEnv;
}

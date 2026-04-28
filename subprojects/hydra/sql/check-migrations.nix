# Returns an attrset of derivations, one per migration step (N -> N+1).
# Each checks that applying upgrade-(N+1).sql to schema version N
# produces the same schema as a fresh load of schema version N+1.
{
  lib,
  stdenv,
  postgresql_17,
  pg-schema-diff,
}:

let
  # unwrapped
  cpp = "${stdenv.cc.cc}/bin/cpp";

  # Extract version numbers from each source
  migrationVersions = map (
    name: lib.toInt (lib.removePrefix "upgrade-" (lib.removeSuffix ".sql" name))
  ) (builtins.attrNames (builtins.readDir ./migrations));

  schemaVersions = map (name: lib.toInt (lib.removePrefix "hydra-" (lib.removeSuffix ".sql" name))) (
    builtins.filter (name: lib.hasSuffix ".sql" name) (builtins.attrNames (builtins.readDir ./schemas))
  );

  allVersions = lib.unique (migrationVersions ++ schemaVersions);

  # A version N is covered when we have schema N-1, schema N, and upgrade-N.sql.
  # Schema-only versions (like version 1, the base) are also covered.
  isCovered =
    n:
    (
      builtins.elem n migrationVersions
      && builtins.elem (n - 1) schemaVersions
      && builtins.elem n schemaVersions
    )
    || (!builtins.elem n migrationVersions && builtins.elem n schemaVersions);

  partitioned = lib.partition isCovered allVersions;
in
assert
  partitioned.wrong == [ ]
  || throw "Missing schemas or migrations for versions: ${toString partitioned.wrong}";

builtins.listToAttrs (
  map (
    to:
    let
      from = to - 1;
      schemaBefore = ./schemas/hydra-${toString from}.sql;
      schemaAfter = ./schemas/hydra-${toString to}.sql;
      migration = ./migrations/upgrade-${toString to}.sql;
    in
    {
      name = "migration-${toString from}-to-${toString to}";
      value = stdenv.mkDerivation {
        name = "check-migration-${toString from}-to-${toString to}";

        dontUnpack = true;

        nativeBuildInputs = [
          postgresql_17
          pg-schema-diff
        ];

        buildPhase = ''
          # Preprocess schema to resolve #ifdef POSTGRESQL / #ifdef SQLITE
          ${cpp} -DPOSTGRESQL -P -undef -nostdinc \
            -traditional-cpp \
            ${schemaBefore} -o "$TMPDIR/schema-before.sql"
          ${cpp} -DPOSTGRESQL -P -undef -nostdinc \
            -traditional-cpp \
            ${schemaAfter} -o "$TMPDIR/schema-after.sql"

          # Put the target schema in a directory for pg-schema-diff
          mkdir -p "$TMPDIR/target-schema"
          cp "$TMPDIR/schema-after.sql" "$TMPDIR/target-schema/"

          export PGDATA="$TMPDIR/pgdata"
          export PGHOST="$TMPDIR/socket"
          mkdir -p "$PGHOST"

          initdb -D "$PGDATA" --no-locale -E UTF8
          pg_ctl -D "$PGDATA" -o "-F -h \"\" -k $PGHOST" -w start

          trap 'pg_ctl -D "$PGDATA" -w stop -m immediate' EXIT

          # --- Build migrated schema ---
          cp ${migration} "$TMPDIR/migration.sql"
        ''
        # Fixup for PG 17 auto-generated constraint names
        # (older PG used numeric suffixes like _fkey2; PG 17 uses column names)
        + lib.optionalString (to == 67) ''
          sed -i \
            -e 's/builds_project_fkey2/builds_project_jobset_job_fkey/g' \
            -e 's/buildmetrics_project_fkey2/buildmetrics_project_jobset_job_fkey/g' \
            -e 's/starredjobs_project_fkey2/starredjobs_project_jobset_job_fkey/g' \
            "$TMPDIR/migration.sql"
        ''
        + ''

          createdb -h "$PGHOST" migrated
          psql -h "$PGHOST" --set ON_ERROR_STOP=1 -f "$TMPDIR/schema-before.sql" migrated
          psql -h "$PGHOST" --set ON_ERROR_STOP=1 -f "$TMPDIR/migration.sql" migrated

          # --- Compare migrated DB against fresh target schema ---
          if ! pg-schema-diff plan \
            --from-dsn "postgresql:///migrated?host=$PGHOST" \
            --to-dir "$TMPDIR/target-schema"; then
            echo ""
            echo "Migration ${toString from} -> ${toString to} produces a different schema than schemas/hydra-${toString to}.sql"
            exit 1
          fi

          echo "Migration ${toString from} -> ${toString to}: OK"
        '';

        installPhase = ''
          touch $out
        '';

        meta.description = "Check migration from schema version ${toString from} to ${toString to}";
      };
    }
  ) (builtins.filter (n: builtins.elem n migrationVersions) partitioned.right)
)

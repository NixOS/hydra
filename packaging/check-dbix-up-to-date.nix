{
  stdenv,
  lib,
  hydra,
  postgresql_17,
  perl,
}:

stdenv.mkDerivation {
  name = "check-dbix-up-to-date";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../subprojects/hydra/sql/hydra.sql
      ../subprojects/hydra/sql/update-dbix.pl
      ../subprojects/hydra/sql/update-dbix-harness.sh
      ../subprojects/hydra/lib
    ];
  };

  nativeBuildInputs = [
    postgresql_17
    hydra.perlDeps
    perl
  ];

  postPatch = ''
    patchShebangs .
  '';

  buildPhase = ''
    # Save the checked-in schema for comparison
    cp -r subprojects/hydra/lib/Hydra/Schema $TMPDIR/schema-before

    # Run the update script
    cd subprojects/hydra/sql
    ./update-dbix-harness.sh
    cd ../../..

    # Compare generated schema against checked-in schema
    if ! diff -ru $TMPDIR/schema-before subprojects/hydra/lib/Hydra/Schema; then
      echo ""
      echo "DBIx schema is out of date!"
      echo "Run ./subprojects/hydra/sql/update-dbix-harness.sh to regenerate."
      exit 1
    fi

    echo "DBIx schema is up to date."
  '';

  installPhase = ''
    touch $out
  '';

  meta.description = "Check that DBIx schema files are up to date with hydra.sql";
}

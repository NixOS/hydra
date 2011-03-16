TESTS_ENVIRONMENT = \
  HYDRA_DBI="dbi:SQLite:db.sqlite" \
  HYDRA_DATA="$(top_srcdir)/tests/data" \
  HYDRA_HOME="$(topsrc_dir)/src" \
  NIX_REMOTE= \
  NIX_STATE_DIR=$(top_srcdir)/tests/nix/var \
  NIX_DATA_DIR=$(top_srcdir)/tests/nix/var \
  NIX_STORE_DIR=$(top_srcdir)/tests/nix/store \
  PERL5LIB=$$PERL5LIB:$(top_srcdir)/src/lib \
  perl -w 

TESTS = \
  query-all-tables.pl

$(TESTS) : db.sqlite dirs

db.sqlite : $(top_srcdir)/src/sql/hydra-sqlite.sql
	sqlite3 db.sqlite <  $(top_srcdir)/src/sql/hydra-sqlite.sql

dirs :
	mkdir -p data
	mkdir -p nix
	mkdir -p nix/store
	mkdir -p nix/var

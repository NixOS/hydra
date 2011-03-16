TESTDIR=`pwd`
TESTS_ENVIRONMENT = \
  HYDRA_DBI="dbi:SQLite:db.sqlite" \
  HYDRA_DATA="$(TESTDIR)/data" \
  HYDRA_HOME="$(topsrc_dir)/src" \
  NIX_REMOTE= \
  NIX_STATE_DIR="$(TESTDIR)/nix/var/nix" \
  NIX_STORE_DIR="$(TESTDIR)/nix/store" \
  NIX_LOG_DIR="$(TESTDIR)/nix/var/log/nix" \
  PERL5LIB=$$PERL5LIB:$(top_srcdir)/src/lib \
  perl -w 

TESTS = \
  query-all-tables.pl \
  evaluation-tests.pl

clean :
	chmod -R a+w nix
	rm -rf db.sqlite data nix

$(TESTS) : clean db.sqlite dirs 

db.sqlite : $(top_srcdir)/src/sql/hydra-sqlite.sql
	sqlite3 db.sqlite <  $(top_srcdir)/src/sql/hydra-sqlite.sql

dirs :
	mkdir -p data
	touch data/hydra.conf
	mkdir -p nix
	mkdir -p nix/store
	mkdir -p nix/var

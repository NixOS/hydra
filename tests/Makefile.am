TESTS_ENVIRONMENT = HYDRA_DBI="dbi:SQLite:db.sqlite" HYDRA_DATA="$(top_srcdir)/tests/data" HYDRA_HOME="$(topsrc_dir)/src"
TESTS = \
  query-all-tables.pl

$(TESTS) : db.sqlite data

db.sqlite : $(top_srcdir)/src/sql/hydra-sqlite.sql
	sqlite3 db.sqlite <  $(top_srcdir)/src/sql/hydra-sqlite.sql

data :
	mkdir -p data

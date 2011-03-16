TESTS = \
  query-all-tables.pl

$(TESTS) : db.sqlite

db.sqlite : $(top_srcdir)/src/sql/hydra-sqlite.sql
	sqlite3 db.sqlite <  $(top_srcdir)/src/sql/hydra-sqlite.sql


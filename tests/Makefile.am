TESTS = \
  query-all-tables.pl

$(TESTS) : db.sqlite

db.sqlite : $(srcdir)/src/sql/hydra-sqlite.sql
	sqlite3 db.sqlite <  $(srcdir)/src/sql/hydra-sqlite.sql


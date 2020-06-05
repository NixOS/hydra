sqldir = $(libexecdir)/hydra/sql
nobase_dist_sql_DATA =				\
  hydra.sql					\
  test.sql					\
  upgrade-*.sql					\
  update-dbix.pl

update-dbix: hydra.sql
	./update-dbix-harness.sh

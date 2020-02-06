sqldir = $(libexecdir)/hydra/sql
nobase_dist_sql_DATA =				\
  hydra-postgresql.sql				\
  hydra.sql					\
  test.sql					\
  upgrade-*.sql					\
  update-dbix.pl

hydra-postgresql.sql: hydra.sql
	cpp -P -E -traditional-cpp -DPOSTGRESQL hydra.sql > $@ || rm -f $@

update-dbix: hydra-postgresql.sql
	./update-dbix-harness.sh

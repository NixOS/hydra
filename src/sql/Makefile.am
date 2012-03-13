sqldir = $(libexecdir)/hydra/sql
nobase_dist_sql_DATA =				\
  hydra-postgresql.sql				\
  hydra.sql					\
  hydra-sqlite.sql				\
  test.sql					\
  upgrade-2.sql					\
  upgrade-3.sql					\
  upgrade-4.sql


hydra-postgresql.sql: hydra.sql
	cpp -P -E -traditional-cpp -DPOSTGRESQL hydra.sql > $@ || rm -f $@

hydra-sqlite.sql: hydra.sql
	cpp -P -E -traditional-cpp -DSQLITE hydra.sql > $@ || rm -f $@

update-dbix: hydra-sqlite.sql
	rm -f tmp.sqlite
	sqlite3 tmp.sqlite < hydra-sqlite.sql
	perl -MDBIx::Class::Schema::Loader=make_schema_at,dump_to_dir:../lib -e 'make_schema_at("Hydra::Schema", { naming => { ALL => "v5" }, relationships => 1, moniker_map => sub {return "$$_";} }, ["dbi:SQLite:tmp.sqlite"])'

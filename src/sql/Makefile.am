sqldir = $(libexecdir)/hydra/sql
nobase_dist_sql_DATA =				\
  hydra-postgresql.sql				\
  hydra.sql					\
  hydra-sqlite.sql				\
  test.sql					\
  upgrade-template-2.sql			\
  upgrade-sqlite-2.sql				\
  upgrade-postgresql-2.sql			\
  upgrade-template-3.sql			\
  upgrade-sqlite-3.sql				\
  upgrade-postgresql-3.sql			\
  upgrade-template-4.sql			\
  upgrade-sqlite-4.sql				\
  upgrade-postgresql-4.sql			\
  upgrade-template-5.sql			\
  upgrade-sqlite-5.sql				\
  upgrade-postgresql-5.sql			\
  upgrade-template-6.sql			\
  upgrade-sqlite-6.sql				\
  upgrade-postgresql-6.sql			\
  upgrade-template-7.sql			\
  upgrade-sqlite-7.sql				\
  upgrade-postgresql-7.sql			\
  upgrade-template-8.sql			\
  upgrade-sqlite-8.sql				\
  upgrade-postgresql-8.sql			\
  upgrade-template-9.sql			\
  upgrade-sqlite-9.sql				\
  upgrade-postgresql-9.sql			\
  upgrade-template-10.sql			\
  upgrade-sqlite-10.sql				\
  upgrade-postgresql-10.sql			\
  upgrade-template-11.sql			\
  upgrade-sqlite-11.sql				\
  upgrade-postgresql-11.sql			\
  upgrade-template-12.sql			\
  upgrade-sqlite-12.sql				\
  upgrade-postgresql-12.sql			

hydra-postgresql.sql: hydra.sql
	cpp -P -E -traditional-cpp -DPOSTGRESQL hydra.sql > $@ || rm -f $@

hydra-sqlite.sql: hydra.sql
	cpp -P -E -traditional-cpp -DSQLITE hydra.sql > $@ || rm -f $@

upgrade-postgresql-%.sql: upgrade-template-%.sql
	cpp -P -E -traditional-cpp -DPOSTGRESQL $< > $@ || rm -f $@

upgrade-sqlite-%.sql: upgrade-template-%.sql
	cpp -P -E -traditional-cpp -DSQLITE $< > $@ || rm -f $@

update-dbix: hydra-sqlite.sql
	rm -f tmp.sqlite
	sqlite3 tmp.sqlite < hydra-sqlite.sql
	perl -MDBIx::Class::Schema::Loader=make_schema_at,dump_to_dir:../lib -e 'make_schema_at("Hydra::Schema", { naming => { ALL => "v5" }, relationships => 1, moniker_map => sub {return "$$_";} }, ["dbi:SQLite:tmp.sqlite"])'

sqldir = $(libexecdir)/hydra/sql
nobase_dist_sql_DATA =				\
  hydra.sql					\
  test.sql					\
  upgrade-*.sql					\
  update-dbix.pl

update-dbix: hydra.sql
	$(SHELL) run-tempdb.sh $< \
	perl -I ../lib -MDBIx::Class::Schema::Loader=make_schema_at,dump_to_dir:../lib update-dbix.pl

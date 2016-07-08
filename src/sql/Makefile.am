sqldir = $(libexecdir)/hydra/sql
nobase_dist_sql_DATA =				\
  hydra.sql					\
  test.sql					\
  upgrade-*.sql					\
  update-dbix.pl

incremential.sql: base.sql upgrade-*.sql run-tempdb.sh
	$(SHELL) run-tempdb.sh -d $@ $< ../script/hydra-init
	perl -i sort-columns.pl $@

singleton.sql: hydra.sql run-tempdb.sh
	$(SHELL) run-tempdb.sh -d $@ $<
	perl -i sort-columns.pl $@

check-db: incremential.sql singleton.sql
	diff -u $^

update-dbix: hydra.sql check-db run-tempdb.sh
	$(SHELL) run-tempdb.sh $< \
	perl -I ../lib -MDBIx::Class::Schema::Loader=make_schema_at,dump_to_dir:../lib update-dbix.pl

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
	rm -rf db.sqlite data nix git-repo hg-repo svn-repo svn-checkout

$(TESTS) : clean db.sqlite dirs 

db.sqlite : $(top_srcdir)/src/sql/hydra-sqlite.sql
	sqlite3 db.sqlite <  $(top_srcdir)/src/sql/hydra-sqlite.sql

dirs :
	mkdir -p data
	touch data/hydra.conf
	mkdir -p nix
	mkdir -p nix/store
	mkdir -p nix/var

git-repo:
	git init git-repo
	touch git-repo/git-file
	(cd git-repo; git add git-file ; git commit -m "add git file" git-file)

hg-repo:
	hg init hg-repo
	touch hg-repo/hg-file
	(cd hg-repo; hg add hg-file ; hg commit -m "add hg file" hg-file)

svn-repo:
	svnadmin create svn-repo
	svn co file://$(TESTDIR)/svn-repo svn-checkout
	touch svn-checkout/svn-file
	svn add svn-checkout/svn-file
	svn commit -m "add svn file" svn-checkout/svn-file

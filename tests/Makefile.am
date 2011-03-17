TESTS_ENVIRONMENT =					\
  BZR_HOME="$(abs_builddir)/data" \
  HYDRA_DBI="dbi:SQLite:db.sqlite"			\
  HYDRA_DATA="$(abs_builddir)/data"				\
  HYDRA_HOME="$(top_srcdir)/src"			\
  NIX_REMOTE=						\
  NIX_STATE_DIR="$(abs_builddir)/nix/var/nix"		\
  NIX_STORE_DIR="$(abs_builddir)/nix/store"			\
  NIX_LOG_DIR="$(abs_builddir)/nix/var/log/nix"		\
  PERL5LIB="$(srcdir):$(top_srcdir)/src/lib:$$PERL5LIB"	\
  PATH=$(abs_top_srcdir)/src/script:$$PATH \
  perl -w 

EXTRA_DIST = \
  $(wildcard *.pm) \
  $(wildcard jobs/*.nix) \
  $(wildcard jobs/*.sh) 

TESTS = \
  query-all-tables.pl \
  evaluation-tests.pl

clean :
	chmod -R a+w nix
	rm -rf db.sqlite data nix git-repo hg-repo svn-repo svn-checkout svn-checkout-repo bzr-repo bzr-checkout-repo

$(TESTS) : db.sqlite dirs 

db.sqlite : $(top_srcdir)/src/sql/hydra-sqlite.sql
	sqlite3 db.sqlite <  $(top_srcdir)/src/sql/hydra-sqlite.sql

dirs : git-repo hg-repo svn-repo svn-checkout-repo bzr-repo bzr-checkout-repo
	mkdir -p data
	touch data/hydra.conf
	mkdir -p nix
	mkdir -p nix/store
	mkdir -p nix/var

git-repo :
	git init git-repo
	touch git-repo/git-file
	(cd git-repo; git add git-file ; git commit -m "add git file" git-file)

hg-repo :
	hg init hg-repo
	touch hg-repo/hg-file
	(cd hg-repo; hg add hg-file ; hg commit -m "add hg file" hg-file)

svn-repo :
	svnadmin create svn-repo
	svn co file://$(abs_builddir)/svn-repo svn-checkout
	touch svn-checkout/svn-file
	svn add svn-checkout/svn-file
	svn commit -m "add svn file" svn-checkout/svn-file

bzr-repo :
	bzr init bzr-repo
	bzr whoami "build <build@donotemail.com>" -d bzr-repo
	touch bzr-repo/bzr-file
	bzr add bzr-repo/bzr-file
	bzr commit -m "add bzr-file" bzr-repo/bzr-file
	
svn-checkout-repo :
	ln -s svn-repo svn-checkout-repo

bzr-checkout-repo :
	ln -s bzr-repo bzr-checkout-repo

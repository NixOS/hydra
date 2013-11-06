TESTS_ENVIRONMENT = \
  BZR_HOME="$(abs_builddir)/data"			\
  HYDRA_DBI="dbi:SQLite:db.sqlite"			\
  HYDRA_DATA="$(abs_builddir)/data"			\
  HYDRA_HOME="$(top_srcdir)/src"			\
  HYDRA_CONFIG=						\
  NIX_REMOTE=						\
  NIX_CONF_DIR="$(abs_builddir)/nix/etc/nix"		\
  NIX_STATE_DIR="$(abs_builddir)/nix/var/nix"		\
  NIX_MANIFESTS_DIR="$(abs_builddir)/nix/var/nix/manifests"	\
  NIX_STORE_DIR="$(abs_builddir)/nix/store"			\
  NIX_LOG_DIR="$(abs_builddir)/nix/var/log/nix"		\
  NIX_BUILD_HOOK=					\
  PERL5LIB="$(srcdir):$(top_srcdir)/src/lib:$$PERL5LIB"	\
  PATH=$(abs_top_srcdir)/src/script:$(abs_top_srcdir)/src/c:$$PATH \
  perl -w

EXTRA_DIST = \
  $(wildcard *.pm) \
  $(wildcard jobs/*.nix) \
  $(wildcard jobs/*.sh) \
  $(TESTS)

TESTS = \
  query-all-tables.pl \
  evaluation-tests.pl

clean:
	chmod -R a+w nix || true
	rm -rf db.sqlite data nix git-repo hg-repo svn-repo svn-checkout svn-checkout-repo bzr-repo bzr-checkout-repo darcs-repo
	rm -f .*-state

check_SCRIPTS = db.sqlite repos

db.sqlite: $(top_srcdir)/src/sql/hydra-sqlite.sql
	$(TESTS_ENVIRONMENT) $(top_srcdir)/src/script/hydra-init

repos: dirs

dirs:
	mkdir -p data
	touch data/hydra.conf
	mkdir -p nix
	mkdir -p nix/etc/nix
	touch nix/etc/nix/nix.conf
	mkdir -p nix/store
	mkdir -p nix/var

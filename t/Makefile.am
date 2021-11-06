TESTS_ENVIRONMENT = \
  BZR_HOME="$(abs_builddir)/data"			\
  HYDRA_DBI="dbi:Pg:dbname=hydra-test-suite;port=6433"	\
  HYDRA_DATA="$(abs_builddir)/data"			\
  HYDRA_HOME="$(top_srcdir)/src"			\
  HYDRA_CONFIG=						\
  NIX_REMOTE=						\
  NIX_REMOTE_SYSTEMS=					\
  NIX_CONF_DIR="$(abs_builddir)/nix/etc/nix"		\
  NIX_STATE_DIR="$(abs_builddir)/nix/var/nix"		\
  NIX_STORE_DIR="$(abs_builddir)/nix/store"			\
  NIX_LOG_DIR="$(abs_builddir)/nix/var/log/nix"		\
  PGHOST=/tmp	\
  PERL5LIB="$(srcdir):$(abs_top_srcdir)/src/lib:$$PERL5LIB"	\
  PYTHONPATH= \
  PATH=$(abs_top_srcdir)/src/hydra-evaluator:$(abs_top_srcdir)/src/script:$(abs_top_srcdir)/src/hydra-eval-jobs:$(abs_top_srcdir)/src/hydra-queue-runner:$$PATH \
  perl -w

EXTRA_DIST = \
  $(wildcard *.pm) \
  $(wildcard jobs/*.nix) \
  $(wildcard jobs/*.sh) \
  $(TESTS)

TESTS = \
  perlcritic.pl \
  test.pl

check_SCRIPTS = repos

repos: dirs

dirs:
	mkdir -p data
	touch data/hydra.conf
	mkdir -p nix
	mkdir -p nix/etc/nix
	mkdir -p nix/store
	mkdir -p nix/var

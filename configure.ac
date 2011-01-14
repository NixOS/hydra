AC_INIT([Hydra], [m4_esyscmd([echo -n $(cat ./version)$VERSION_SUFFIX])],
        [nix-dev@cs.uu.nl], [hydra], [http://nixos.org/hydra/])
AM_INIT_AUTOMAKE([foreign])

AC_PROG_CC
AC_PROG_INSTALL
AC_PROG_LN_S
AC_PROG_LIBTOOL
AC_PROG_CXX

AC_PATH_PROG(dblatex, dblatex)


AC_DEFUN([NEED_PROG],
[
AC_PATH_PROG($1, $2)
if test -z "$$1"; then
    AC_MSG_ERROR([$2 is required])
fi
])

NEED_PROG(perl, perl)

AC_ARG_WITH(nix, AC_HELP_STRING([--with-nix=PATH],
  [prefix of nix]),
  nix=$withval, nix=/nix-missing)
AC_SUBST(nix)

AC_CONFIG_FILES([
  Makefile

  doc/Makefile
  doc/manual/Makefile

  src/Makefile
  src/c/Makefile
  src/sql/Makefile
  src/xsl/Makefile
  src/lib/Makefile
  src/root/Makefile

  src/script/Makefile
  src/script/hydra_build.pl
  src/script/hydra_create.pl
  src/script/hydra_evaluator.pl
  src/script/hydra_queue_runner.pl
  src/script/hydra_server.pl
  src/script/hydra_update_gc_roots.pl
])
AC_OUTPUT


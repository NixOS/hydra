AC_INIT([Hydra], [m4_esyscmd([echo -n $(cat ./version)$VERSION_SUFFIX])],
        [nix-dev@cs.uu.nl], [hydra], [http://nixos.org/hydra/])
AM_INIT_AUTOMAKE([foreign])

AC_LANG([C++])

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

old_CPPFLAGS="$CPPFLAGS"
old_LIBS="$LIBS"

CPPFLAGS="-I$nix/include/nix"
LIBS="-L$nix/lib/nix"

AC_CHECK_HEADER([store-api.hh], [:],
  [AC_MSG_ERROR([Nix headers not found; please install Nix or check the `--with-nix' option.])])
AC_CHECK_LIB([expr], [_ZN3nix17parseExprFromFileERNS_9EvalStateESs], [:],
  [AC_MSG_ERROR([Nix library not found; please install Nix or check the `--with-nix' option.])])

CPPFLAGS="$old_CPPFLAGS"
LIBS="$old_LIBS"

PKG_CHECK_MODULES([BDW_GC], [bdw-gc])

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

  tests/Makefile
  tests/query-all-tables.pl
])
AC_OUTPUT


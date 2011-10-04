AC_INIT([Hydra], [m4_esyscmd([echo -n $(cat ./version)$VERSION_SUFFIX])],
        [nix-dev@cs.uu.nl], [hydra], [http://nixos.org/hydra/])
AM_INIT_AUTOMAKE([foreign])

AC_LANG([C++])

AC_PROG_CC
AC_PROG_INSTALL
AC_PROG_LN_S
AC_PROG_LIBTOOL
AC_PROG_CXX

dnl Optional dependencies to build the manual, normally not needed
dnl since the tarball comes with the PDF and HTML manuals.
AC_PATH_PROG([DBLATEX], [dblatex])
AC_PATH_PROG([XSLTPROC], [xsltproc])

AC_ARG_WITH([docbook-xsl],
  [AS_HELP_STRING([--with-docbook-xsl=PATH],
    [path of the DocBook XSL stylesheets])],
  [docbookxsl="$withval"],
  [docbookxsl="/docbook-xsl-missing"])
AC_SUBST([docbookxsl])


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
LDFLAGS="-L$nix/lib/nix"

AC_CHECK_HEADER([store-api.hh], [:],
  [AC_MSG_ERROR([Nix headers not found; please install Nix or check the `--with-nix' option.])])
AC_CHECK_LIB([expr], [_ZN3nix9EvalState17parseExprFromFileESs], [:],
  [AC_MSG_ERROR([Nix library not found; please install Nix or check the `--with-nix' option.])])

CPPFLAGS="$old_CPPFLAGS"
LIBS="$old_LIBS"

PKG_CHECK_MODULES([BDW_GC], [bdw-gc])

testPath="$(dirname $(type -p expr))"
AC_SUBST(testPath)

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
  tests/Makefile
  tests/jobs/config.nix
])

AC_CONFIG_FILES([src/script/hydra_build.pl], [chmod +x src/script/hydra_build.pl])
AC_CONFIG_FILES([src/script/hydra_create.pl], [chmod +x src/script/hydra_create.pl])
AC_CONFIG_FILES([src/script/hydra_evaluator.pl], [chmod +x src/script/hydra_evaluator.pl])
AC_CONFIG_FILES([src/script/hydra_queue_runner.pl], [chmod +x src/script/hydra_queue_runner.pl])
AC_CONFIG_FILES([src/script/hydra_server.pl], [chmod +x src/script/hydra_server.pl])
AC_CONFIG_FILES([src/script/hydra_update_gc_roots.pl], [chmod +x src/script/hydra_update_gc_roots.pl])
AC_CONFIG_FILES([tests/query-all-tables.pl], [chmod +x tests/query-all-tables.pl])
AC_CONFIG_FILES([tests/evaluation-tests.pl], [chmod +x tests/evaluation-tests.pl])

AC_OUTPUT


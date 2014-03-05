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

PATH="$nix/bin:$PATH"
export PATH

NEED_PROG([NIX_STORE_PROGRAM], [nix-store])

AC_MSG_CHECKING([whether $NIX_STORE_PROGRAM is recent enough])
if test -n "$NIX_STORE" -a -n "$TMPDIR"
then
    # This may be executed from within a build chroot, so pacify
    # `nix-store' instead of letting it choke while trying to mkdir
    # /nix/var.
    NIX_STATE_DIR="$TMPDIR"
    export NIX_STATE_DIR
fi
if NIX_REMOTE=daemon "$NIX_STORE_PROGRAM" --timeout 123 -q; then 
    AC_MSG_RESULT([yes])
else
    AC_MSG_RESULT([no])
    AC_MSG_ERROR([`$NIX_STORE_PROGRAM' doesn't support `--timeout'; please use a newer version.])
fi

old_CPPFLAGS="$CPPFLAGS"
old_LIBS="$LIBS"

CPPFLAGS="$CPPFLAGS -I$nix/include/nix"
LDFLAGS="$LDFLAGS -L$nix/lib/nix"

AC_CHECK_HEADER([store-api.hh], [:],
  [AC_MSG_ERROR([Nix headers not found; please install Nix or check the `--with-nix' option.])])
AC_CHECK_LIB([nixexpr], [_ZN3nix9EvalState8evalFileERKSsRNS_5ValueE], [:],
  [AC_MSG_ERROR([Nix library not found; please install Nix or check the `--with-nix' option.])])

CPPFLAGS="$old_CPPFLAGS"
LIBS="$old_LIBS"

PKG_CHECK_MODULES([BDW_GC], [bdw-gc])
PKG_CHECK_MODULES([GUILE], [guile-2.0], [HAVE_GUILE=yes], [HAVE_GUILE=no])

if test "x$HAVE_GUILE" = xyes; then
  AC_PATH_PROG([GUILE], [guile])
else
  GUILE="guile"
fi
AC_SUBST([GUILE])

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
  src/ttf/Makefile
  src/lib/Makefile
  src/root/Makefile
  src/script/Makefile
  src/script/hydra-eval-guile-jobs
  tests/Makefile
  tests/jobs/config.nix
])

AC_CONFIG_COMMANDS([executable-scripts],
  [chmod +x src/script/hydra-eval-guile-jobs])

AC_OUTPUT

AC_INIT([Hydra], [m4_esyscmd([echo -n $(cat ./version.txt)$VERSION_SUFFIX])])
AC_CONFIG_AUX_DIR(config)
AM_INIT_AUTOMAKE([foreign serial-tests])

AC_LANG([C++])

AC_PROG_CC
AC_PROG_INSTALL
AC_PROG_LN_S
AC_PROG_LIBTOOL
AC_PROG_CXX

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
if NIX_REMOTE=daemon PAGER=cat "$NIX_STORE_PROGRAM" --timeout 123 -q; then
    AC_MSG_RESULT([yes])
else
    AC_MSG_RESULT([no])
    AC_MSG_ERROR([`$NIX_STORE_PROGRAM' doesn't support `--timeout'; please use a newer version.])
fi

PKG_CHECK_MODULES([NIX], [nix-main nix-expr nix-store])

testPath="$(dirname $(type -p expr))"
AC_SUBST(testPath)

CXXFLAGS+=" -include nix/config.h"

AC_CONFIG_FILES([
  Makefile
  doc/Makefile
  doc/manual/Makefile
  src/Makefile
  src/hydra-evaluator/Makefile
  src/hydra-eval-jobs/Makefile
  src/hydra-queue-runner/Makefile
  src/sql/Makefile
  src/ttf/Makefile
  src/lib/Makefile
  src/root/Makefile
  src/script/Makefile
])

# Tests might be filtered out
AM_CONDITIONAL([CAN_DO_CHECK], [test -f "$srcdir/t/api-test.t"])
AM_COND_IF(
  [CAN_DO_CHECK],
  [
    jobsPath="$(realpath ./t/jobs)"
    AC_SUBST(jobsPath)
    AC_CONFIG_FILES([
      t/Makefile
      t/jobs/config.nix
      t/jobs/declarative/project.json
    ])
  ])

AC_CONFIG_COMMANDS([executable-scripts], [])

AC_CONFIG_HEADER([hydra-config.h])

AC_OUTPUT

#! /bin/sh
set -e

repo="$1"
STATE_FILE=$(pwd)/.hg-state
if test -e $STATE_FILE; then
    state=$(cat $STATE_FILE)
    test $state -gt 1 && state=0
else
    state=0;
fi

case $state in
    (0) echo "::Create repo. -- continue -- updated::"
    mkdir darcs-repo
    darcs init --repodir darcs-repo
    touch darcs-repo/file
    darcs add --repodir darcs-repo file
    darcs record --repodir darcs-repo -a -l -m "add a file" file -A foobar@bar.bar
    ;;
    (*) echo "::End. -- stop -- nothing::" ;;
esac

echo $(($state + 1)) > $STATE_FILE

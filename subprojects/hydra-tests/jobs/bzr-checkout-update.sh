#! /bin/sh

repo="$1"
STATE_FILE=$(pwd)/.bzr-checkout-state
if test -e $STATE_FILE; then
    state=$(cat $STATE_FILE)
    test $state -gt 1 && state=0
else
    state=0;
fi

export BZR_HOME; # Set by the Makefile
case $state in
    (0) echo "::Create repo. -- continue -- updated::"
    bzr init bzr-repo
    bzr whoami "build <build@invalid.org>" -d bzr-repo
    touch bzr-repo/bzr-file
    bzr add bzr-repo/bzr-file
    bzr commit -m "add bzr-file" bzr-repo/bzr-file
    ln -s bzr-repo bzr-checkout-repo
    ;;
    (*) echo "::End. -- stop -- nothing::" ;;
esac

echo $(($state + 1)) > $STATE_FILE

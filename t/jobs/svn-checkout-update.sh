#! /bin/sh

repo="$1"
STATE_FILE=$(pwd)/.svn-checkout-state
if test -e $STATE_FILE; then
    state=$(cat $STATE_FILE)
    test $state -gt 1 && state=0
else
    state=0;
fi

case $state in
    (0) echo "::Create repo. -- continue -- updated::"
    svnadmin create svn-repo
    svn co file://$PWD/$repo svn-checkout
    touch svn-checkout/svn-file
    svn add svn-checkout/svn-file
    svn commit -m "add svn file" svn-checkout/svn-file
    ln -s svn-repo svn-checkout-repo
    ;;
    (*) echo "::End. -- stop -- nothing::" ;;
esac

echo $(($state + 1)) > $STATE_FILE

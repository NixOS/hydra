#! /bin/sh
set -e

repo=git-repo
export HOME=$(pwd)
STATE_FILE=$(pwd)/.git-rev-state
if test -e $STATE_FILE; then
    state=1
    rm $STATE_FILE
else
    state=0
    touch $STATE_FILE
fi

echo "STATE: $state"
case $state in
    (0) echo "::Create repo. -- continue -- updated::"
    git init $repo
    cd $repo
    git config --global user.email "you@example.com"
    git config --global user.name "Your Name"

    touch foo
    git add foo
    GIT_AUTHOR_DATE="1970-01-01T00:00:00 +0000" GIT_COMMITTER_DATE="1970-01-01T00:00:00 +0000" git commit -m "Add foo"
    ;;
    (*) echo "::End. -- stop -- nothing::"
    rm -rf $repo
    ;;
esac

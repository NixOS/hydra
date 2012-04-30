#! /bin/sh
# This script is used both by git & deepgit checks.

repo=git-repo
STATE_FILE=$(pwd)/.git-state
if test -e $STATE_FILE; then
    state=$(cat $STATE_FILE)
    test $state -gt 3 && state=0
else
    state=0;
fi

case $state in
    (0) echo "::Create repo. -- continue -- updated::"
    git init $repo
    cd $repo
    touch foo
    git add foo
    git commit -m "Add foo"
    git tag -a -m "First Tag." tag0
    git checkout -b master HEAD
    ;;
    (1) echo "::Create new commit. -- continue -- updated::"
    cd $repo
    # Increase depth to make sure the tag is not fetched by default.
    echo 0 > foo
    git add foo
    git commit -m "Increase depth 0"
    echo 1 > foo
    git add foo
    git commit -m "Increase depth 1"
    echo 2 > foo
    git add foo
    git commit -m "Increase depth 2"
    echo 0 > bar
    git add bar
    git commit -m "Add bar with 0"
    ;;
    (2) echo "::Amend commit. (push -f) -- continue -- updated::"
    cd $repo
    echo 1 > bar
    git add bar
    git commit --amend -m "Add bar with 1"
    ;;
    (*) echo "::End. -- stop -- nothing::"
    rm -rf $repo
    ;;
esac

echo $(($state + 1)) > $STATE_FILE

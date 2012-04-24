#! /bin/sh

cd "$1"
STATE_FILE=.state
if test -e $STATE_FILE; then
    state=$(cat $STATE_FILE)
else
    state=0;
fi

case $state in
    (0)
    echo "Add new file."
    touch git-file-2
    git add git-file-2 >&2
    git commit -m "add git file 2" git-file-2 >&2
    ;;
    (1)
    echo "Rewrite commit."
    echo 1 > git-file-2
    git add git-file-2 >&2
    git commit --amend -m "add git file 2" git-file-2 >&2
    ;;
esac

echo $(($state + 1)) > $STATE_FILE

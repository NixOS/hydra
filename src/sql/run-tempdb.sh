if [ $# -lt 2 ]; then
    echo "Usage: $0 SQL-FILE COMMAND [ARG...]" >&2
    exit 1
fi

if dbpath="$(mktemp -d)"; then
    setup() {
        initdb -D "$dbpath"
        pg_ctl -D "$dbpath" -o "-F -k "$dbpath" -p 5432 -h ''" -w start
        createdb -h "$dbpath" -p 5432 hydra
    }

    teardown() {
        pg_ctl -D "$dbpath" stop
        rm -rf "$dbpath"
    }

    trap teardown EXIT
    setup > /dev/null

    psql -h "$dbpath" -p 5432 -f "$1" hydra > /dev/null
    export HYDRA_DBI="dbi:Pg:dbname=hydra;port=5432;host=$dbpath"
    shift
    "$@"
fi

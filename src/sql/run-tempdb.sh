print_usage() {
    echo "Usage: $0 [options] SQL-FILE [COMMAND [ARG...]]" >&2
    echo >&2
    echo "Options:" >&2
    echo "  -d FILE   Dump schema to FILE afterwards." >&2
}

if [ $# -lt 2 ]; then
    print_usage
    exit 1
fi

dumpdb=""
while getopts "d:" option; do
    case "$option" in
        d) dumpdb="$OPTARG";;
        \?) echo "Invalid option -$OPTARG">&2; print_usage;;
        :) echo "-$OPTARG requires an argument." >&2; print_usage;;
        *) print_usage; exit 1;;
    esac
done

shift $((OPTIND - 1))

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

    set -e
    setup > /dev/null

    psql -h "$dbpath" -p 5432 -f "$1" hydra > /dev/null
    export HYDRA_DBI="dbi:Pg:dbname=hydra;port=5432;host=$dbpath"
    shift
    "$@"

    if [ -n "$dumpdb" ]; then
        pg_dump -s -h "$dbpath" -p 5432 hydra > "$dumpdb"
    fi
fi

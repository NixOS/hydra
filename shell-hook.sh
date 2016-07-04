hydra_devdir="$PWD/inst"
export HYDRA_HOME="$PWD/src"

function setup-dev-env() {
    HYDRA_DATA="$hydra_devdir/data"
    HYDRA_DBI="dbi:Pg:dbname=hydra;port=5432;host=$hydra_devdir/sockets"
    export HYDRA_DATA HYDRA_DBI
}

function stop-database() {
    if [ -e "$hydra_devdir/database/postmaster.pid" ]; then
        pg_ctl -D "$hydra_devdir/database" stop
    fi
}

function start-database() {
    mkdir -p "$hydra_devdir/sockets"
    pg_ctl -D "$hydra_devdir/database" \
        -o "-F -k '$hydra_devdir/sockets' -p 5432 -h ''" -w start
    trap stop-database EXIT
}

if [ -e "$hydra_devdir/database" ]; then
    setup-dev-env
    start-database
fi

function setup-database() {
    if [ ! -e "$HYDRA_HOME/sql/hydra-postgresql.sql" ]; then
        echo "hydra-postgresql.sql doesn't exist, please run make!" >&2
        return 1
    fi
    initdb -D "$hydra_devdir/database" \
        && start-database \
        && setup-dev-env \
        && createdb -p 5432 -h "$hydra_devdir/sockets" hydra \
        && mkdir -p "$HYDRA_DATA" \
        && hydra-init
}

sourceRoot="$PWD"
hydraDevDir="$sourceRoot/inst"
export HYDRA_HOME="$sourceRoot/src"

function setupEnvVars() {
    HYDRA_DATA="$hydraDevDir/data"
    HYDRA_DBI="dbi:Pg:dbname=hydra;port=5432;host=$hydraDevDir/sockets"
    export HYDRA_DATA HYDRA_DBI
}

function stop-database() {
    if [ -e "$hydraDevDir/database/postmaster.pid" ]; then
        pg_ctl -D "$hydraDevDir/database" stop
    fi
}

function start-database() {
    mkdir -p "$hydraDevDir/sockets"
    pg_ctl -D "$hydraDevDir/database" \
        -o "-F -k '$hydraDevDir/sockets' -p 5432 -h ''" -w start
    trap stop-database EXIT
}

if [ -e "$hydraDevDir/database" ]; then
    setupEnvVars
    start-database
fi

function setup-database() {
    if [ ! -e "$HYDRA_HOME/sql/hydra-postgresql.sql" ]; then
        echo "hydra-postgresql.sql doesn't exist, please run make!" >&2
        return 1
    fi
    initdb -D "$hydraDevDir/database" \
        && start-database \
        && setup-dev-env \
        && createdb -p 5432 -h "$hydraDevDir/sockets" hydra \
        && mkdir -p "$HYDRA_DATA" \
        && hydra-init
}

function setup-dev-env() {
    if [ ! -e "$sourceRoot/configure" ]; then
        "$sourceRoot/bootstrap"
    fi
    if [ ! -e Makefile ]; then
        "$sourceRoot/configure" $configureFlags
    fi
    if [ ! -e "$HYDRA_HOME/sql/hydra-postgresql.sql" ]; then
        make
    fi
    if [ ! -e "$hydraDevDir/database" ]; then
        setup-database
    fi
}

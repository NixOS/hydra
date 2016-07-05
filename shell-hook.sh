sourceRoot="$PWD"
hydraDevDir="$sourceRoot/inst"
export HYDRA_HOME="$sourceRoot/src"

function setupEnvVars() {
    PGDATABASE=hydra
    PGHOST="$hydraDevDir/sockets"
    PGPORT=5432
    HYDRA_DATA="$hydraDevDir/data"
    HYDRA_DBI="dbi:Pg:dbname=$PGDATABASE;port=$PGPORT;host=$PGHOST"
    export PGDATABASE PGHOST PGPORT HYDRA_DATA HYDRA_DBI
}

function stop-database() {
    if [ -e "$hydraDevDir/database/postmaster.pid" ]; then
        pg_ctl -D "$hydraDevDir/database" stop
    fi
}

function start-database() {
    [ -e "$hydraDevDir/database/postmaster.pid" ] \
        && kill -0 "$(< "$hydraDevDir/database/postmaster.pid")" \
        && return 0
    mkdir -p "$hydraDevDir/sockets"
    local setsid="$(type -P setsid 2> /dev/null || :)"
    $setsid pg_ctl -D "$hydraDevDir/database" \
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
    setupEnvVars
    initdb -D "$hydraDevDir/database" \
        && start-database \
        && createdb -p 5432 -h "$hydraDevDir/sockets" hydra \
        && mkdir -p "$HYDRA_DATA" \
        && hydra-init \
        && return 0
    return 1
}

function setup-dev-env() {
    if [ ! -e "$sourceRoot/configure" ]; then
        "$sourceRoot/bootstrap" || return 1
    fi
    if [ ! -e Makefile ]; then
        "$sourceRoot/configure" $configureFlags || return 1
    fi
    if [ ! -e "$HYDRA_HOME/sql/hydra-postgresql.sql" ]; then
        make || return 1
    fi
    if [ ! -e "$hydraDevDir/database" ]; then
        setup-database || return 1
        hydra-create-user admin --password admin --role admin || return 1
    fi
}

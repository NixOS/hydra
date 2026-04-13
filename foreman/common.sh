# Shared constants and helpers for the foreman scripts.
# Sourced (not executed) by start-*.sh.

# Ports
HYDRA_PG_PORT=64444
HYDRA_SERVER_PORT=63333
HYDRA_PROMETHEUS_PORT=64445
HYDRA_QUEUE_RUNNER_GRPC_PORT=50051

# Paths
HYDRA_DATA=$(pwd)/.hydra-data
HYDRA_HOME=$(pwd)/subprojects/hydra
HYDRA_PG_SOCKET_DIR=$HYDRA_DATA/postgres

# Connection strings
HYDRA_DBI="dbi:Pg:dbname=hydra;host=localhost;port=$HYDRA_PG_PORT"

# Cargo target dir picked from the meson build type set in the dev shell.
if [ "${mesonBuildType:-}" = "debug" ]; then
    cargo_profile=debug
else
    cargo_profile=release
fi
HYDRA_CARGO_TARGET_DIR=$(pwd)/target/$cargo_profile

export PATH=$HYDRA_HOME/script:$HYDRA_CARGO_TARGET_DIR:$(pwd)/build/subprojects/hydra/hydra-evaluator:$PATH
export PERL5LIB=$(pwd)/subprojects/hydra/lib:$PERL5LIB

wait_for_postgres() {
    while ! pg_isready -h "$HYDRA_PG_SOCKET_DIR" -p "$HYDRA_PG_PORT"; do sleep 1; done
}

wait_for_hydra_server() {
    while ! nc -z localhost "$HYDRA_SERVER_PORT"; do sleep 1; done
}

wait_for_queue_runner_grpc() {
    while ! nc -z ::1 "$HYDRA_QUEUE_RUNNER_GRPC_PORT" 2>/dev/null; do sleep 1; done
}

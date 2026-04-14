#!/bin/sh

. ./foreman/common.sh

wait_for_postgres

# wait until the hydra database exists (hydra-server creates it)
while ! psql -h "$HYDRA_PG_SOCKET_DIR" -p "$HYDRA_PG_PORT" -d hydra -c 'SELECT 1' >/dev/null 2>&1; do sleep 1; done

wait_for_hydra_server

DAEMON_SOCK="$HYDRA_DATA/drv-daemon.sock"
UPSTREAM_SOCK="${NIX_DAEMON_SOCKET_PATH:-/nix/var/nix/daemon-socket/socket}"

export HYDRA_DBA="postgres://${USER}@localhost:$HYDRA_PG_PORT/hydra"

exec hydra-drv-daemon \
    --socket "$DAEMON_SOCK" \
    --upstream-socket "$UPSTREAM_SOCK"

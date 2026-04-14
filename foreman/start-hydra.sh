#!/bin/sh

. ./foreman/common.sh

export HYDRA_HOME
export HYDRA_DATA
export HYDRA_DBI

wait_for_postgres

createdb -h "$HYDRA_PG_SOCKET_DIR" -p "$HYDRA_PG_PORT" hydra

# create a db for the default user. Not sure why, but
# the terminal is otherwise spammed with:
#
#     FATAL:  database "USERNAME" does not exist
createdb -h "$HYDRA_PG_SOCKET_DIR" -p "$HYDRA_PG_PORT" "$(whoami)" || true

ln -sf ../../../../build/subprojects/hydra/{bootstrap,fontawesome} subprojects/hydra/root/static

hydra-init
hydra-create-user alice --password foobar --role admin

if [ ! -f "$HYDRA_DATA/hydra.conf" ]; then
    echo "Creating a default hydra.conf"
    cat << EOF > "$HYDRA_DATA/hydra.conf"
# Use substitutes in dev instances to avoid bootstrapping nixpkgs.
use-substitutes = true

# IFD evaluation is allowed in the dev shell so the Procfile drv-daemon
# (started by start-evaluator.sh via NIX_REMOTE) actually sees those
# builds. Drop this line to disable IFD entirely.
allow_import_from_derivation = true

<hydra_notify>
  <prometheus>
    listen_address = 127.0.0.1
    port = $HYDRA_PROMETHEUS_PORT
  </prometheus>
</hydra_notify>
EOF
fi
HYDRA_CONFIG=$HYDRA_DATA/hydra.conf exec hydra-dev-server --port "$HYDRA_SERVER_PORT" --restart --debug

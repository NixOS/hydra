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
# test-time instances likely don't want to bootstrap nixpkgs from scratch
use-substitutes = true

<hydra_notify>
  <prometheus>
    listen_address = 127.0.0.1
    port = $HYDRA_PROMETHEUS_PORT
  </prometheus>
</hydra_notify>
EOF
fi
HYDRA_CONFIG=$HYDRA_DATA/hydra.conf exec hydra-dev-server --port "$HYDRA_SERVER_PORT" --restart --debug

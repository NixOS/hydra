#!/bin/sh

. ./foreman/common.sh

wait_for_postgres
wait_for_hydra_db
wait_for_hydra_server

CONFIG="$HYDRA_DATA/queue-runner.toml"

# Generate a config for the Rust queue-runner if it doesn't exist
if [ ! -f "$CONFIG" ]; then
    cat <<EOF > "$CONFIG"
hydraDataDir = "$HYDRA_DATA"
rootsDir = "$HYDRA_DATA/gcroots"
useSubstitutes = true
EOF
fi

export HYDRA_DATABASE_URL="postgres://${USER}@localhost:$HYDRA_PG_PORT/hydra"
export LOGNAME="${LOGNAME:-$USER}"

exec hydra-queue-runner -c "$CONFIG" --rest-bind - --grpc-bind -

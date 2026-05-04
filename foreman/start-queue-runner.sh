#!/bin/sh

. ./foreman/common.sh

wait_for_postgres

# wait until the hydra database exists (hydra-server creates it)
while ! psql -h "$HYDRA_PG_SOCKET_DIR" -p "$HYDRA_PG_PORT" -d hydra -c 'SELECT 1' >/dev/null 2>&1; do sleep 1; done

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

exec hydra-queue-runner -c "$CONFIG"

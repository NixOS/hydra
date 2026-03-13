#!/bin/sh

# wait for postgresql
while ! pg_isready -h $(pwd)/.hydra-data/postgres -p 64444; do sleep 1; done

# wait until the hydra database exists (hydra-server creates it)
while ! psql -h $(pwd)/.hydra-data/postgres -p 64444 -d hydra -c 'SELECT 1' >/dev/null 2>&1; do sleep 1; done

# wait until hydra-server is listening
while ! nc -z localhost 63333; do sleep 1; done

HYDRA_DATA=$(pwd)/.hydra-data
CONFIG="$HYDRA_DATA/queue-runner.toml"

# Generate a config for the Rust queue-runner if it doesn't exist
if [ ! -f "$CONFIG" ]; then
    cat <<EOF > "$CONFIG"
hydraDataDir = "$HYDRA_DATA"
rootsDir = "$HYDRA_DATA/gcroots"
useSubstitutes = true
EOF
fi

export HYDRA_DATABASE_URL="postgres://${USER}@localhost:64444/hydra"
export LOGNAME="${LOGNAME:-$USER}"

exec hydra-queue-runner -c "$CONFIG"

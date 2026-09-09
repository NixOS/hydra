#!/bin/sh

. ./foreman/common.sh

wait_for_postgres
wait_for_hydra_db
wait_for_hydra_server

CONFIG="$HYDRA_DATA/ad-hoc.toml"

# Generate a config for hydra-ad-hoc if it doesn't exist
if [ ! -f "$CONFIG" ]; then
    cat <<EOT > "$CONFIG"
upstreamSocket = "${NIX_DAEMON_SOCKET_PATH:-/nix/var/nix/daemon-socket/socket}"
EOT
fi

export HYDRA_DATABASE_URL="postgres://${USER}@localhost:$HYDRA_PG_PORT/hydra"

# TODO: the other services get their listeners from foreman via the
# Socketfile, but the fork only knows how to bind TCP addresses. Once
# it can hand out a Unix domain socket, declare this one there and pass
# `--socket -` like the NixOS module does.
exec hydra-ad-hoc --socket "$HYDRA_DATA/ad-hoc.sock" -c "$CONFIG"

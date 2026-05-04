#!/bin/sh

. ./foreman/common.sh

export HYDRA_DBI
export HYDRA_DATA

wait_for_postgres
wait_for_hydra_server

# Route IFD store ops through the drv-daemon when its socket is up.
# When the socket is missing the evaluator falls back to the local nix-daemon.
DAEMON_SOCK="$HYDRA_DATA/drv-daemon.sock"
if [ -S "$DAEMON_SOCK" ]; then
    export NIX_REMOTE="unix://$DAEMON_SOCK"
fi

HYDRA_CONFIG=$HYDRA_DATA/hydra.conf exec hydra-evaluator

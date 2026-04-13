#!/bin/sh

. ./foreman/common.sh

initdb "$HYDRA_PG_SOCKET_DIR"
exec postgres -D "$HYDRA_PG_SOCKET_DIR" -k "$HYDRA_PG_SOCKET_DIR" -p "$HYDRA_PG_PORT"

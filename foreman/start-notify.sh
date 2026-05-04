#!/bin/sh

. ./foreman/common.sh

export HYDRA_HOME
export HYDRA_DATA
export HYDRA_DBI

wait_for_postgres
wait_for_hydra_server

HYDRA_CONFIG=$HYDRA_DATA/hydra.conf exec hydra-notify

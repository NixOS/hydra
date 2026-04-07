#!/bin/sh

. ./foreman/common.sh

export HYDRA_DBI
export HYDRA_DATA

wait_for_postgres
wait_for_hydra_server

HYDRA_CONFIG=$HYDRA_DATA/hydra.conf exec hydra-evaluator

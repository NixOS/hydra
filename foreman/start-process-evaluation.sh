#!/bin/sh

. ./foreman/common.sh

export HYDRA_DATABASE_URL
export HYDRA_DATA

wait_for_postgres
wait_for_hydra_db
wait_for_hydra_server

exec hydra-process-evaluation

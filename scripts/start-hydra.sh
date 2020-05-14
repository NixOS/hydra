#!/bin/sh

# wait for postgresql to be up
while ! pg_ctl -D $(pwd)/.hydra-data/postgres status; do sleep 1; done

createdb -h $(pwd)/.hydra-data/postgres -p 64444 hydra

hydra-init
hydra-create-user alice --password foobar --role admin

touch .hydra-data/hydra.conf
HYDRA_CONFIG=$(pwd)/.hydra-data/hydra.conf exec hydra-server --port 63333

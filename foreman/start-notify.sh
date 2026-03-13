#!/bin/sh

export PATH=$(pwd)/src/script:$PATH

# wait for postgresql and hydra-server
while ! pg_isready -h $(pwd)/.hydra-data/postgres -p 64444; do sleep 1; done
while ! nc -z localhost 63333; do sleep 1; done

HYDRA_CONFIG=$(pwd)/.hydra-data/hydra.conf exec hydra-notify

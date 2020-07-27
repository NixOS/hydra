#!/bin/sh

# wait for hydra-server to listen
while ! nc -z localhost 63333; do sleep 1; done

HYDRA_CONFIG=$(pwd)/.hydra-data/hydra.conf exec hydra-notify

#!/bin/sh

# wait until hydra is listening on port 63333
while ! nc -z localhost 63333; do sleep 1; done

NIX_REMOTE_SYSTEMS="" HYDRA_CONFIG=$(pwd)/.hydra-data/hydra.conf exec hydra-queue-runner

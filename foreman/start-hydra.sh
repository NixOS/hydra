#!/bin/sh

# wait for postgresql to listen
while ! pg_isready -h $(pwd)/.hydra-data/postgres -p 64444; do sleep 1; done

createdb -h $(pwd)/.hydra-data/postgres -p 64444 hydra

hydra-init
hydra-create-user alice --password foobar --role admin

if [ ! -f ./.hydra-data/hydra.conf ]; then
    echo "Creating a default hydra.conf"
    cat << EOF > .hydra-data/hydra.conf
# test-time instances likely don't want to bootstrap nixpkgs from scratch
use-substitutes = true
EOF
fi
HYDRA_CONFIG=$(pwd)/.hydra-data/hydra.conf exec hydra-dev-server --port 63333

#!/bin/sh

# wait for postgresql to listen
while ! pg_isready ; do sleep 1; done

createdb hydra

# create a db for the default user. Not sure why, but
# the terminal is otherwise spammed with:
#
#     FATAL:  database "USERNAME" does not exist
createdb "$(whoami)" || true

hydra-init
hydra-create-user alice --password foobar --role admin

if [ ! -f ./.hydra-data/hydra.conf ]; then
    echo "Creating a default hydra.conf"
    cat << EOF > .hydra-data/hydra.conf
# test-time instances likely don't want to bootstrap nixpkgs from scratch
use-substitutes = true

<hydra_notify>
  <prometheus>
    listen_address = 127.0.0.1
    port = 64445
  </prometheus>
</hydra_notify>
EOF
fi
HYDRA_CONFIG=$(pwd)/.hydra-data/hydra.conf exec hydra-dev-server --port 63333 --restart --debug

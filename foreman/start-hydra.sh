#!/bin/sh

export PATH=$(pwd)/src/script:$PATH

# wait for postgresql to listen
while ! pg_isready -h $(pwd)/.hydra-data/postgres -p 64444; do sleep 1; done
# We need to wait for kanidm to be up and start-kanidm.pl to have written the secret file.
while ! curl -ksf  "https://localhost:64448/status"; do sleep 1; done
while ! [[ -e .hydra-data/kanidm/hydra_client_secret ]]; do sleep 1; done

createdb -h $(pwd)/.hydra-data/postgres -p 64444 hydra

# create a db for the default user. Not sure why, but
# the terminal is otherwise spammed with:
#
#     FATAL:  database "USERNAME" does not exist
createdb -h $(pwd)/.hydra-data/postgres -p 64444 "$(whoami)" || true

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

<oidc>
  <provider kanidm>
    display_name = "Kanidm"
    discovery_url = "https://localhost:64448/oauth2/openid/hydra/.well-known/openid-configuration"
    client_id = "hydra"
    client_secret_file = ".hydra-data/kanidm/hydra_client_secret"
    ca_file = ".hydra-data/kanidm/ca.pem"
  </provider>
</oidc>
EOF
fi
HYDRA_CONFIG=$(pwd)/.hydra-data/hydra.conf exec hydra-dev-server --port 63333 --restart --debug

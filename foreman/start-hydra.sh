#!/bin/sh

export PATH=$(pwd)/src/script:$PATH

# wait for postgresql to listen
while ! pg_isready -h $(pwd)/.hydra-data/postgres -p 64444; do sleep 1; done
# We need to not only wait for keycloak to be up, but also for start-keycloak.sh to have created
# the hydra-dev realm
while ! curl -sf  "http://localhost:64446/realms/hydra-dev/.well-known/openid-configuration"; do sleep 1; done

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
  <provider keycloak>
    display_name = "Keycloak"
    discovery_url = "http://localhost:64446/realms/hydra-dev/.well-known/openid-configuration"
    client_id = "hydra-local"
    client_secret = "hydra-local-secret"
  </provider>
</oidc>
EOF
fi
HYDRA_CONFIG=$(pwd)/.hydra-data/hydra.conf exec hydra-dev-server --port 63333 --restart --debug

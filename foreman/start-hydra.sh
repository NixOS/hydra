#!/bin/sh

. ./foreman/common.sh

export HYDRA_HOME
export HYDRA_DATA
export HYDRA_DATABASE_URL

wait_for_postgres

# We need to wait for kanidm to be up and start-kanidm.pl to have written the secret file.
while ! curl -ksf "https://localhost:$HYDRA_KANIDM_PORT/status"; do sleep 1; done
while ! [[ -e .hydra-data/kanidm/hydra_client_secret ]]; do sleep 1; done

createdb -h "$HYDRA_PG_SOCKET_DIR" -p "$HYDRA_PG_PORT" hydra

# create a db for the default user. Not sure why, but
# the terminal is otherwise spammed with:
#
#     FATAL:  database "USERNAME" does not exist
createdb -h "$HYDRA_PG_SOCKET_DIR" -p "$HYDRA_PG_PORT" "$(whoami)" || true

ln -sf ../../../../build/subprojects/hydra/{bootstrap,fontawesome} subprojects/hydra/root/static

hydra-init
hydra-create-user alice --password foobar --role admin

if [ ! -f "$HYDRA_DATA/hydra.conf" ]; then
    echo "Creating a default hydra.conf"
    cat << EOF > "$HYDRA_DATA/hydra.conf"
# test-time instances likely don't want to bootstrap nixpkgs from scratch
use-substitutes = true
queue_runner_endpoint = http://localhost:$HYDRA_QUEUE_RUNNER_REST_PORT
ws_endpoint = ws://localhost:$HYDRA_WS_PORT

<hydra_notify>
  <prometheus>
    listen_address = 127.0.0.1
    port = $HYDRA_PROMETHEUS_PORT
  </prometheus>
</hydra_notify>

<oidc>
  <provider kanidm>
    display_name = "Kanidm"
    discovery_url = "https://localhost:$KANIDM_PORT/oauth2/openid/hydra/.well-known/openid-configuration"
    client_id = "hydra"
    client_secret_file = ".hydra-data/kanidm/hydra_client_secret"
    ca_file = ".hydra-data/kanidm/ca.pem"
  </provider>
</oidc>
EOF
fi
HYDRA_CONFIG=$HYDRA_DATA/hydra.conf exec hydra-dev-server -r -d --port "$HYDRA_SERVER_PORT"

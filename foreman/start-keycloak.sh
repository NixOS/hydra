#!/bin/sh

set -ex

KEYCLOAK_STORE_PATH="$(realpath "$(dirname "$(which kc.sh)")"/..)"
export KC_HOME_DIR="./.hydra-data/keycloak"
export KC_CONF_DIR="./.hydra-data/keycloak/conf"
KEYCLOAK_URL="http://localhost:64446"
KEYCLOAK_ADMIN_URL="http://localhost:64447"
REALM_NAME="hydra-dev"
CLIENT_ID="hydra-local"
CLIENT_SECRET="hydra-local-secret"
HYDRA_URL="http://localhost:63333"
export KC_DB=postgres
export KC_DB_URL="jdbc:postgresql://localhost:64444/keycloak"
export KC_DB_USERNAME="$USER"
export KC_DB_PASSWORD=""
export KC_HTTP_PORT="64446"
export KC_HEALTH_ENABLED=true
export KC_HTTP_MANAGEMENT_SCHEME="http"
export KC_HTTP_MANAGEMENT_PORT="64447"
export KC_HTTP_MANAGEMENT_HEALTH_ENABLED=true
export KC_HTTP_ENABLED=true
export KC_HTTPS_ENABLED=false
export KC_HOSTNAME_STRICT=false
export KC_BOOTSTRAP_ADMIN_USERNAME="admin"
export KC_BOOTSTRAP_ADMIN_PASSWORD="admin"
export KC_CACHE=local

while ! pg_isready -h $(pwd)/.hydra-data/postgres -p 64444; do sleep 1; done

createdb -h "$(pwd)/.hydra-data/postgres" -p 64444 keycloak 2>/dev/null || true

# Create Keycloak data and work directories
# This is what the nixpkgs keycloak module does
mkdir -p "$KC_HOME_DIR"
mkdir -p "$KC_HOME_DIR/conf"
ln -snf "$KEYCLOAK_STORE_PATH/themes" "$KC_HOME_DIR/themes"
ln -snf "$KEYCLOAK_STORE_PATH/providers" "$KC_HOME_DIR/providers"
ln -snf "$KEYCLOAK_STORE_PATH/lib" "$KC_HOME_DIR/lib"

# Start keycloak, but keep the script running. Forward signals to it to make
# sure it dies when foreman kills us. This is kind of needed because foreman
# is a bit anemic and has no post-start kind of thing.
kc.sh start --verbose &
KEYCLOAK_PID=$!
trap "kill -TERM $KEYCLOAK_PID && wait $KEYCLOAK_PID" EXIT

while ! curl -sf  "$KEYCLOAK_ADMIN_URL/health/ready"; do sleep 1; done

cat > "$KC_HOME_DIR/realm.json" <<EOF
{
  "realm": "$REALM_NAME",
  "enabled": true,
  "registrationAllowed": false,
  "resetPasswordAllowed": true,
  "displayName": "Hydra Development Realm",
  "roles": {
    "client": {
      "hydra-local": [
        {
          "name": "admin",
          "description": "Hydra Administrator"
        },
        {
          "name": "restart-jobs",
          "description": "Restart Hydra jobs"
        },
        {
          "name": "bump-to-front",
          "description": "Bump Hydra jobs to the front of the queue"
        }
      ]
    }
  },
  "clients": [
    {
      "clientId": "$CLIENT_ID",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "secret": "$CLIENT_SECRET",
      "redirectUris": ["$HYDRA_URL/oidc-callback/keycloak"],
      "webOrigins": ["$HYDRA_URL"],
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": false,
      "consentRequired": false,
      "fullScopeAllowed": true,
      "attributes": {
        "pkce.code.challenge.method": "S256"
      },
      "protocolMappers": [
        {
          "name": "hydra-roles-mapper",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-usermodel-client-role-mapper",
          "consentRequired": false,
          "config": {
            "introspection.token.claim": "true",
            "multivalued": "true",
            "userinfo.token.claim": "false",
            "id.token.claim": "true",
            "lightweight.claim": "false",
            "access.token.claim": "true",
            "claim.name": "hydra_roles",
            "jsonType.label": "String",
            "usermodel.clientRoleMapping.clientId": "hydra-local"
          }
        }
      ]
    }
  ],
  "users": [
    {
      "username": "testuser",
      "enabled": true,
      "email": "testuser@example.com",
      "emailVerified": true,
      "firstName": "Test",
      "lastName": "User",
      "credentials": [
        {
          "type": "password",
          "value": "testpass",
          "temporary": false
        }
      ],
      "clientRoles": {
        "hydra-local": ["admin"]
      }
    }
  ]
}
EOF

# Configure kcadm to use our server
kcadm.sh config credentials --server "$KEYCLOAK_URL" --realm master \
    --user "admin" --password "admin"

if ! kcadm.sh get realms/$REALM_NAME > /dev/null 2>&1; then
    kcadm.sh create realms -f "$KC_HOME_DIR/realm.json"
fi

# Our trap signal will ensure keycloak dies when we get a term signal
while true; do sleep 100000; done;

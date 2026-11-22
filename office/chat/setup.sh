#!/bin/sh
# Starts ejabberd. Run again when Keycloak's signing key changes (key rotation).
set -e
cd "$(dirname "$0")"
. ./.env

# Keycloak's public signing key; ejabberd checks login tokens with it (one key only)
key=$(curl -fsS --resolve "$AUTH_HOST:443:127.0.0.1" "$ISSUER/protocol/openid-connect/certs" | jq -e '.keys[] | select(.use == "sig" and .alg == "RS256")')
echo "$key" > keycloak.jwk
mkdir -p upload && chown 9000:9000 upload    # ejabberd runs as uid 9000
docker compose up -d --force-recreate

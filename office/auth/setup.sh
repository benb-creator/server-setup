#!/bin/sh
# Starts Keycloak (imports realm.json on first start) and connects Active Directory if AD_URL is set.
set -e
cd "$(dirname "$0")"
. ./.env
docker compose up -d --wait
# The realm is imported after start; wait until it is served (via the local Caddy)
until curl -fsS --resolve "$AUTH_HOST:443:127.0.0.1" "$ISSUER/.well-known/openid-configuration" > /dev/null; do
  echo "Waiting for $ISSUER ..."; sleep 5
done
[ -z "$AD_URL" ] || ./ad.sh

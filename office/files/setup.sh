#!/bin/sh
# Starts Nextcloud and sets up login with Keycloak: on the web, and with bearer tokens on WebDAV.
# User id = email address, as in mail and chat. Accounts are created at first login. Safe to run again.
set -e
cd "$(dirname "$0")"
. ./.env
docker compose up -d
occ() { docker exec -u www-data nextcloud php occ "$@"; }
until occ status 2>/dev/null | grep -q "installed: true"; do echo "Waiting for Nextcloud to install ..."; sleep 10; done

occ config:system:set allow_local_remote_servers --type=boolean --value=true    # Keycloak is reached via Docker's network
occ app:install user_oidc || occ app:enable user_oidc
occ user_oidc:provider keycloak --clientid=files --clientsecret="$NEXTCLOUD_OIDC_SECRET" \
  --discoveryuri="$ISSUER/.well-known/openid-configuration" \
  --mapping-uid=email --unique-uid=0 --mapping-display-name=name --mapping-email=email \
  --check-bearer=1 --bearer-provisioning=1
occ config:app:set user_oidc allow_multiple_user_backends --value=0    # login page goes straight to Keycloak
occ background:cron

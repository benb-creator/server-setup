#!/bin/sh
# Makes Stalwart load the certificate that Caddy renewed. Run daily, e.g. cron: 0 4 * * * /opt/office/mail/reload-cert.sh
cd "$(dirname "$0")" && . ./.env
docker run --rm --network office -e STALWART_URL=http://stalwart:8080 -e STALWART_USER=admin \
  -e STALWART_PASSWORD="$STALWART_ADMIN_PASSWORD" stalwartlabs/cli:2 create Action/ReloadTlsCertificates

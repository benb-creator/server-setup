#!/bin/sh
# Writes all DNS records to zones/DOMAIN.zone and shows or applies them at your DNS provider.
#   ./dns.sh         zone file, plus a preview of the changes at your DNS provider
#   ./dns.sh push    zone file, and apply the changes at your DNS provider
# DNS provider: add a "dns" entry to creds.json (see TODO.md). Without it, you only get the zone file.
set -e
cd "$(dirname "$0")"
. ./.env
[ -f creds.json ] || echo '{"bind": {"TYPE": "BIND", "directory": "zones"}}' > creds.json
mkdir -p zones && rm -f "zones/$DOMAIN.zone"
[ -f ../mail/dkim.key ] || openssl genrsa -out ../mail/dkim.key 2048    # DNS comes before mail, so create it here
dkim=$(openssl rsa -in ../mail/dkim.key -pubout 2>/dev/null | grep -v -- ----- | tr -d '\n')

dnscontrol() {
  docker run --rm -v "$PWD:/dns" dnscontrol/dnscontrol:5.10.1 "$@" \
    -v domain="$DOMAIN" -v ip4="$PUBLIC_IP" -v ip6="$PUBLIC_IP6" -v dkim="$dkim" -v selector="$DKIM_SELECTOR" \
    -v auth_host="$AUTH_HOST" -v mail_host="$MAIL_HOST" -v chat_host="$CHAT_HOST" -v meet_host="$MEET_HOST" -v files_host="$FILES_HOST"
}

dnscontrol push --providers bind -v provider= -v mail_records=yes
echo "Zone file: dns/zones/$DOMAIN.zone"

if grep -q '"dns"' creds.json; then
  dnscontrol "${1:-preview}" --providers dns -v provider=yes -v mail_records="$DNS_MAIL_RECORDS"
fi

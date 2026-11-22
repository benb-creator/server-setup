#!/bin/sh
# Starts and configures Stalwart. Safe to run again after changing .env.
set -e
cd "$(dirname "$0")"
. ./.env

# DKIM key; its public half goes into DNS (dns/dns.sh reads it from here)
[ -f dkim.key ] || openssl genrsa -out dkim.key 2048
chmod 644 dkim.key
docker compose up -d --wait

# Wait for Caddy to get the certificate for MAIL_HOST (needs DNS pointing here)
cert=acme-v02.api.letsencrypt.org-directory/$MAIL_HOST/$MAIL_HOST
until [ -f "../proxy/data/caddy/certificates/$cert.crt" ]; do echo "Waiting for the certificate of $MAIL_HOST ..."; sleep 10; done

cli() { docker run --rm -i --network office -e STALWART_URL=http://stalwart:8080 -e STALWART_USER=admin \
  -e STALWART_PASSWORD="$STALWART_ADMIN_PASSWORD" stalwartlabs/cli:2 "$@"; }

# Settings, as a stalwart-cli plan: one JSON object per line. Lines starting with # are dropped.
grep -v '^#' <<END | cli apply --stdin
# Mail domain. We bring our own DKIM key, so Stalwart must not generate one.
{"@type":"upsert","object":"Domain","matchOn":["name"],"value":{"domain":{"name":"$DOMAIN","dkimManagement":{"@type":"Manual"}}}}
{"@type":"update","object":"SystemSettings","value":{"defaultHostname":"$MAIL_HOST","defaultDomainId":"#domain"}}
{"@type":"upsert","object":"DkimSignature","matchOn":["selector"],"value":{"dkim":{"@type":"Dkim1RsaSha256","domainId":"#domain","selector":"$DKIM_SELECTOR","privateKey":{"@type":"File","filePath":"/etc/stalwart/dkim.key"},"stage":"active"}}}
# TLS certificate from Caddy. reload-cert.sh (daily cron) picks up renewals.
{"@type":"upsert","object":"Certificate","matchOn":["certificate"],"value":{"cert":{"certificate":{"@type":"File","filePath":"/certs/$cert.crt"},"privateKey":{"@type":"File","filePath":"/certs/$cert.key"}}}}
# Login with Keycloak access tokens; the account name is the email address
{"@type":"upsert","object":"Directory","matchOn":["description"],"value":{"keycloak":{"@type":"Oidc","description":"Keycloak","issuerUrl":"$ISSUER","claimUsername":"email","claimName":"name","acceptedAudiences":{"mail":true},"unscopedTokens":"interoperable"}}}
{"@type":"update","object":"Authentication","value":{"directoryId":"#keycloak"}}
# The web UI logs in via Keycloak too (client "mail" in auth/realm.json)
{"@type":"upsert","object":"Application","matchOn":["description"],"value":{"webui":{"description":"Stalwart Web Interface","oauthClientId":"mail"}}}
# Behind Caddy: take the client IP from X-Forwarded-For
{"@type":"update","object":"Http","value":{"clientIpSource":"xForwardedFor"}}
# Log to the console, for "docker logs stalwart"
{"@type":"upsert","object":"Tracer","matchOn":["@type"],"value":{"stdout":{"@type":"Stdout","enable":true,"level":"info"}}}
# Also accept mail submission on port 587 (STARTTLS)
{"@type":"upsert","object":"NetworkListener","matchOn":["name"],"value":{"submission":{"name":"submission","protocol":"smtp","bind":{"[::]:587":true}}}}
END

# Split domain: accept mail for all of DOMAIN; users without a mailbox here are relayed to MAIL_RELAY_HOST
if [ -n "$MAIL_RELAY_HOST" ]; then
grep -v '^#' <<END | cli apply --stdin
{"@type":"upsert","object":"Domain","matchOn":["name"],"value":{"domain":{"name":"$DOMAIN","allowRelaying":true}}}
{"@type":"upsert","object":"MtaRoute","matchOn":["name"],"value":{"split":{"@type":"Relay","name":"split","host":"$MAIL_RELAY_HOST","port":25,"protocol":"smtp","implicitTls":false}}}
{"@type":"update","object":"MtaOutboundStrategy","value":{"route":{"match":{"0":{"if":"is_local_address(rcpt)","then":"'local'"},"1":{"if":"is_local_domain(rcpt_domain)","then":"'split'"}},"else":"'mx'"}}}
END
fi

docker compose restart    # new listeners need a restart

# TODO: set everything up by hand, step by step

About 30 minutes, plus waiting for DNS. Each step sets up one service. To do it all in one go
instead, run `./setup.sh` (see README.md); it does exactly these steps.

Commands run on the server as root, in `/opt/office`.

## 1. Before you start (5 min)

- [ ] A Linux server with:
  - Docker and the compose plugin (`docker compose version` works)
  - `curl`, `jq`, `openssl` and cron (`apt install -y curl jq openssl cron`)
  - a public IPv4 address
- [ ] Firewall open for 80, 443, 25, 465, 587, 993 (TCP), 7881 (TCP), 7882 and 3478 (UDP).
- [ ] Outgoing port 25 is not blocked by your provider.
- [ ] Access to your DNS: a login at the DNS provider, or someone who can enter records.
- [ ] Optional, for AD and Windows SSO: an AD service account, and a domain admin for step 7b.

## 2. Get the files (1 min)

```bash
git clone https://github.com/benb-creator/server-setup.git
```

```bash
cp -r server-setup/office /opt/office && cd /opt/office
```

## 3. Settings (3 min)

```bash
cp .env.example .env && chmod 600 .env
```

- [ ] Edit `.env`: set `DOMAIN`, `ORG_NAME`, `ADMIN_EMAIL` and `PUBLIC_IP`. Change the host names if you like.
- [ ] Split domain (a second mail system for some users): set `MAIL_RELAY_HOST`, see PLAN.md section 4.
- [ ] Replace every `CHANGEME` with its own random secret:

```bash
while grep -q CHANGEME .env; do sed -i "0,/CHANGEME/s//$(openssl rand -hex 20)/" .env; done
```

## 4. DNS (5 min, plus waiting)

```bash
dns/dns.sh
```

This writes `dns/zones/DOMAIN.zone`. Then do one of these:
- [ ] **By hand:** enter the records from the zone file at your DNS provider (skip SOA). Many providers can also import a zone file.
- [ ] **Automatically:** put your provider login into `dns/creds.json`, next to the `bind` entry. Then run `dns/dns.sh` to preview and `dns/dns.sh push` to apply. Examples (all providers: https://docs.dnscontrol.org/provider/index):
  ```json
  "dns": {"TYPE": "CLOUDFLAREAPI", "apitoken": "..."}
  "dns": {"TYPE": "ROUTE53", "KeyId": "...", "SecretKey": "..."}
  "dns": {"TYPE": "POWERDNS", "apiUrl": "https://pdns.example.com:8081", "apiKey": "...", "serverName": "localhost"}
  ```
- [ ] **Mail routing records:** MX, SPF and DMARC are in the zone file, but are only pushed if `DNS_MAIL_RECORDS=yes`. For a domain that already has mail, change the MX only when you switch over, and merge `mx` into your existing SPF record.
- [ ] Check: `dig +short auth.DOMAIN` shows `PUBLIC_IP`. The other host names must resolve too before step 6 can get certificates.

## 5. Network and database (1 min)

```bash
docker network create office
```

```bash
cd postgres && docker compose up -d --wait && cd ..
```

## 6. Caddy: HTTPS (1 min)

```bash
cd proxy && docker compose up -d && cd ..
```

- [ ] Within a minute, `docker logs caddy` should show "certificate obtained successfully" for each host name.

## 7. Keycloak: login (3 min)

```bash
auth/setup.sh
```

- [ ] Open `https://auth.DOMAIN/admin/` and log in as user `admin` with the password `KEYCLOAK_ADMIN_PASSWORD` from `.env`.
- [ ] Switch to realm **office**. Under Users, create a test user with an email address in DOMAIN, then set a password under Credentials.
- [ ] Restrict the admin console: set `ADMIN_NETWORKS` in `.env` to your admin network, then run `cd proxy && docker compose up -d --force-recreate`.

### 7b. Optional: Active Directory and Windows SSO (10 min)

- [ ] In `.env`, set `AD_URL`, `AD_BIND_DN`, `AD_BIND_PASSWORD` and `AD_USERS_DN`.
- [ ] For LDAPS with an internal CA, put the CA certificate (PEM) into `auth/truststore/`.
- [ ] For Windows SSO, create a keytab on a domain controller. Use a dedicated AD account, here `svc-keycloak-http`, with "password never expires":
  ```
  ktpass /out keycloak.keytab /princ HTTP/auth.DOMAIN@AD.REALM /mapuser AD\svc-keycloak-http /pass * /crypto AES256-SHA1 /ptype KRB5_NT_PRINCIPAL
  ```
  Then copy it to `auth/kerberos/keycloak.keytab` (`chmod 644`) and set `AD_KERBEROS_REALM=AD.REALM` in `.env`.
- [ ] Run `auth/setup.sh` (it runs `auth/ad.sh`). Keycloak imports the AD users, then syncs changes every 5 minutes.
- [ ] Group Policy for the browsers:
  - Edge and Chrome: add `https://auth.DOMAIN` to the Intranet zone ("Site to Zone Assignment List"), or set `AuthServerAllowlist`.
  - Firefox: `network.negotiate-auth.trusted-uris`.

## 8. Stalwart: mail, calendar, contacts (3 min)

```bash
mail/setup.sh
```

- [ ] Add the daily certificate reload (`crontab -e`):
  ```
  0 4 * * * /opt/office/mail/reload-cert.sh > /dev/null
  ```

## 9. ejabberd: chat (1 min)

```bash
chat/setup.sh
```

- [ ] XMPP clients find the WebSocket URL at `https://DOMAIN/.well-known/host-meta`, which is your main website. There, redirect `/.well-known/host-meta` and `/.well-known/host-meta.json` to `https://chat.DOMAIN/...` (same path).

## 10. LiveKit: meetings (1 min)

```bash
cd meet && docker compose up -d && cd ..
```

## 11. Nextcloud: files (3 min)

```bash
files/setup.sh
```

## 12. Sync: provisioning (1 min)

```bash
cd sync && docker compose up -d && cd ..
```

- [ ] `docker logs sync` should show `stalwart: create user@DOMAIN` for your test user.

## 13. Test (3 min)

```bash
./test.sh
```

- [ ] Log in as the test user in the browser when asked. Every line should say `ok`.
- [ ] Mail: send a test mail to an outside address and back. Check SPF and DKIM, e.g. with mail-tester.com.
- [ ] Chat: log in with an XMPP client at `wss://chat.DOMAIN/xmpp-websocket`, using the access token as password.
- [ ] Deprovisioning:
  1. Disable the test user in Keycloak.
  2. Run `docker restart sync` (it syncs at start), or wait 5 minutes.
  3. `docker logs sync` shows "suspend" and "disable".

## 14. Afterwards

- [ ] Back up `/opt/office` (including `.env` and `mail/dkim.key`) and run `pg_dumpall` regularly.
- [ ] Register the redirect URIs and client IDs your apps need in Keycloak (client `office`).
- [ ] Updates: change the image tag in a `compose.yml`, then run `docker compose pull && docker compose up -d`.

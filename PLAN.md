# Plan: mail and collaboration for one organization

Goal: one organization (company, government office, university) gets mail, calendar,
contacts, chat, video meetings and files. Everything is open source, on premises and
runs in Docker. There is one login (Keycloak) and OAuth2 in every protocol. Windows SSO
is optional.

This repo is a blueprint. Every service lives in its own folder with a small config, so
you can set each one up by hand, swap it for another product, or move it to its own server.

## 1. Overview

```
         Clients (desktop, mobile, web): OAuth2 login at Keycloak, then a bearer token everywhere
                                         │
     ports 25 465 587 993                │ 80 443                        7881/tcp 7882/udp 3478/udp
            │                    ┌───────▼────────┐                                │
     ┌──────▼──────┐  ◄─────────┤     Caddy      ├────────────────►  ┌────────────▼┐
     │  Stalwart   │  mail.     │ HTTPS, routing  │  meet.            │   LiveKit   │◄── meet-token
     │ mail, cal,  │            └─┬──────┬─────┬──┘                   └─────────────┘   (Keycloak token
     │  contacts   │       auth.  │ chat.│     │ files.                                   → room token)
     └──────┬──────┘     ┌────────▼─┐ ┌──▼───────┐ ┌▼──────────┐
            │            │ Keycloak │ │ ejabberd │ │ Nextcloud │
            │            └──┬────┬──┘ └────┬─────┘ └─────┬─────┘
            │      AD (LDAP │    │         │             │
            │     +Kerberos)┘    │         │             │
            └────────────────────┴─ PostgreSQL ──────────┘   (one database per service)

     sync: reads users from Keycloak → creates, disables, deletes accounts in Stalwart, Nextcloud, ejabberd, SCIM apps
```

| Function | Software | Clients use | Host name | Folder |
|---|---|---|---|---|
| Login | Keycloak 26.8 | OAuth2, OpenID Connect | auth.DOMAIN | `office/auth` |
| Mail, calendar, contacts | Stalwart 1.1 | JMAP, IMAP, SMTP, CalDAV, CardDAV | mail.DOMAIN | `office/mail` |
| Chat | ejabberd 26.09 | XMPP over WebSocket | chat.DOMAIN | `office/chat` |
| Meetings | LiveKit 1.13 | WebRTC | meet.DOMAIN | `office/meet` |
| Files | Nextcloud 34 | WebDAV | files.DOMAIN | `office/files` |
| Provisioning | `sync.py` (about 200 lines, standard library only) | – | – | `office/sync` |
| HTTPS, certificates | Caddy 2 | HTTPS | all of the above | `office/proxy` |
| Database | PostgreSQL 18 | – | – | `office/postgres` |
| DNS | DNSControl | – | – | `office/dns` |

All settings are in one file, `office/.env`. Every service folder links to it, and every
config file reads its values from there:
- Docker Compose: `${VAR}`
- Caddy: `{$VAR}`
- Keycloak realm import: `${VAR}`
- ejabberd: `EJABBERD_MACRO_*`
- LiveKit: `LIVEKIT_*` environment variables
- Stalwart: the plan in `setup.sh`

So the manual steps (TODO.md) and the script (`setup.sh` / Ansible) use exactly the same files.

## 2. Authentication

**Clients.** Apps get tokens from Keycloak with the authorization code flow and PKCE (RFC 8252):
- Client `office`, a public client.
- Redirect to `http://127.0.0.1:<any port>`, or the device flow for devices without a browser.
- The access token is a JWT, valid for 5 minutes. Its `aud` claim holds `mail chat meet files`.
- Clients renew access tokens with the refresh token (scope `offline_access` for long-lived sessions).

**Servers.** Each server checks the token itself:

| Server | How it checks the token | User identity | Account |
|---|---|---|---|
| Stalwart | OIDC directory: checks the JWT against Keycloak's keys and requires audience `mail` | `email` claim | pre-created by sync (mail must arrive before the first login); otherwise at first login |
| ejabberd | `auth_method: jwt`: checks the signature with Keycloak's public key; the token is the SASL PLAIN password | `email` claim = JID | not needed |
| LiveKit | `meet-token` asks Keycloak's userinfo endpoint, checks audience `meet`, then issues a LiveKit room token | `email` claim | not needed |
| Nextcloud | app `user_oidc`: checks the JWT against Keycloak's keys and requires audience `files` | `email` claim = user id | created at the first login or WebDAV request |

The email address is the user's identity everywhere: mail address, chat address and files user.

Mail clients that only speak IMAP and SMTP use the same token with SASL `OAUTHBEARER` or `XOAUTH2`.

**Discovery.** Clients can find the login server in two ways:
- Stalwart publishes `https://mail.DOMAIN/.well-known/oauth-protected-resource` (RFC 9728), which names Keycloak as the authorization server.
- Keycloak's own metadata is at `ISSUER/.well-known/openid-configuration`.

Stalwart's mail autoconfig (`autoconfig.DOMAIN`) lists the servers, but advertises password
authentication, not OAuth2.

**Web login.** Nextcloud (client `files`) and the Stalwart web UI (client `mail`) send the
user to Keycloak.

**User sources.** Keycloak keeps its own users, imports them from Active Directory, or both.
- `auth/ad.sh` connects AD read-only.
- Users are imported and changes are synced every 5 minutes, including "account disabled" (`userAccountControl`).
- A user created in AD or in Keycloak can log in to every service.

**Windows SSO.**
1. The user logs in to Windows and gets a Kerberos ticket.
2. The app opens Keycloak in the browser (or system web view).
3. The browser sends the ticket (SPNEGO) to `auth.DOMAIN`.
4. Keycloak logs the user in without asking for a password.

Requirements:
- A service account in AD with the SPN `HTTP/auth.DOMAIN`.
- Its keytab in `auth/kerberos/`.
- `auth.DOMAIN` in the browsers' intranet zone (Group Policy).
- Users outside the domain get the normal login form.

## 3. Provisioning and deprovisioning

Ideally every server creates accounts on demand and receives SCIM messages for disable and
delete. In practice (state of late 2026):
- Keycloak has no outbound SCIM. Version 26.8 has a SCIM *server* only. The third-party plugins for outbound SCIM are unreleased or unmaintained.
- A disable in AD reaches Keycloak by LDAP sync, which creates no Keycloak event.
- Stalwart's SCIM server is in the Enterprise edition only.
- Nextcloud's SCIM app supports Nextcloud 30 at most.
- ejabberd and LiveKit have no user accounts at all with token login.

So one small service, `sync`, does the job. Keycloak is the source of truth.
- It reconciles every `SYNC_INTERVAL` seconds (default 300), and immediately on any `POST http://sync:8080/`.
- That POST is the event hook. For example, a Keycloak event-listener webhook such as vymalo/keycloak-webhook (MIT) can call it.

| Target | Create | Disable / re-enable | Delete (`SYNC_DELETE=true`) | API |
|---|---|---|---|---|
| Stalwart | mailbox for each enabled user with an address in DOMAIN (only members of `MAIL_GROUP`, if set) | suspend: no login, no sending; mail is still received | delete mailbox | JMAP management API |
| Nextcloud | (at first login) | `user:disable` / `user:enable` | delete user | OCS provisioning API |
| ejabberd | (none needed) | disconnect sessions | delete roster and history | `mod_http_api` |
| any SCIM 2.0 app (`SYNC_TARGETS=... scim`, `SCIM_TARGETS`) | `POST /Users` | `PATCH active` | `DELETE /Users/{id}` | SCIM 2.0 |

How quickly a disabled user loses access:
- Keycloak issues no new tokens to a disabled user, and existing access tokens expire after 5 minutes.
- Stalwart and Nextcloud refuse even still-valid tokens as soon as sync has run.
- `meet-token` asks Keycloak every time, so it refuses at once.
- ejabberd accepts a still-valid token until it expires; sync disconnects the user's sessions on every run.

Safety rules:
- Sync never touches accounts it does not know. In Stalwart those are accounts without the Keycloak id in `externalId`, e.g. shared mailboxes. In Nextcloud they are local users such as `admin`.
- It skips a run if Keycloak returns no users at all.
- Without `SYNC_DELETE=true` it only disables.

For a SCIM-capable product, for example Stalwart Enterprise at `/scim/v2`, add `scim` to
`SYNC_TARGETS` in `sync/compose.yml` and set `SCIM_TARGETS="https://host/scim/v2|token"`.

## 4. Split domain: two mail systems for one domain

Some domains keep a second mail system (e.g. Exchange) for part of the users, temporarily
or for good. Set `MAIL_RELAY_HOST` to that system. Stalwart then:
1. accepts mail for every address in DOMAIN;
2. delivers it locally if the mailbox exists here;
3. relays all other addresses of DOMAIN to `MAIL_RELAY_HOST`, including mail from local users;
4. sends mail for other domains via MX as usual.

Who has a mailbox on Stalwart:
- Without `MAIL_GROUP`: everyone in Keycloak with an address in DOMAIN.
- With `MAIL_GROUP=stalwart-users`: only members of that Keycloak or AD group. To migrate users, add them to the group.

Which system receives the mail from the internet (MX):
- **Stalwart is MX:** set `DNS_MAIL_RECORDS=yes`. The other system must accept relayed mail from Stalwart's IP.
- **The other system stays MX:** keep `DNS_MAIL_RECORDS=no`. Configure the other system to forward mail for Stalwart users to `mail.DOMAIN` (Exchange: an internal-relay accepted domain plus a send connector).

Caveat: the first login at Stalwart creates a mailbox there. Users who live on the other
system should not log in to Stalwart. With `MAIL_GROUP` set, sync suspends such mailboxes.

## 5. DNS

`office/dns/dns.sh` writes all records to `dns/zones/DOMAIN.zone`. With a DNS provider login
in `dns/creds.json`, it also previews (`./dns.sh`) or applies (`./dns.sh push`) them there.
This uses DNSControl, which supports about 50 providers, among them Cloudflare, Route 53,
Azure, Google, Hetzner, OVH, PowerDNS, BIND, RFC 2136 and Windows DNS.

| Record | Purpose |
|---|---|
| A (and AAAA) for auth, mail, chat, meet, files, autoconfig, autodiscover | services |
| `office1._domainkey` TXT | DKIM key; the private key is `mail/dkim.key` |
| SRV `_submissions`, `_submission`, `_imaps`, `_jmap`, `_caldavs`, `_carddavs` | client discovery (RFC 6186, 8314, 6764, 8620) |
| MX, SPF (`v=spf1 mx -all`), `_dmarc` | only with `DNS_MAIL_RECORDS=yes`, because they replace existing records |

The existing DNS stays untouched:
- `NO_PURGE` keeps every record that is not in this list.
- Ansible stops if the provider would modify an existing record.

XMPP WebSocket discovery (XEP-0156) is looked up at `https://DOMAIN/.well-known/host-meta`,
which is your main website. Caddy serves these files on `chat.DOMAIN`. Add a redirect on
the website (see TODO.md).

## 6. Scaling to 30,000 users, or 10,000 office plus 100,000 light users

The default is a single host. That suits a pilot or a few thousand users: 16 cores, 64 GB RAM
and fast disks are a reasonable start. To grow, move each folder to its own servers and
scale it out. Same images, same settings:

| Component | Scale out by | Start with, for 30,000 users |
|---|---|---|
| PostgreSQL | dedicated servers, primary plus replica (e.g. Patroni); one cluster per service if needed | 2 to 3 servers |
| Stalwart | cluster mode: shared PostgreSQL (or FoundationDB), blobs in S3 (Garage, SeaweedFS, Ceph), Valkey or Stalwart Keep for coordination. Nodes are stateless; put an L4 load balancer with the PROXY protocol in front of SMTP and IMAP | 3 nodes plus an S3 cluster |
| Keycloak | more nodes on the same database; they cluster automatically | 2 to 3 nodes |
| ejabberd | Erlang cluster on the same database, WebSocket behind the load balancer | 2 nodes |
| LiveKit | more nodes sharing one Redis or Valkey (`LIVEKIT_REDIS_ADDRESS`); each node needs a public IP | 2 to 6 nodes, depending on concurrent video users |
| Nextcloud | more app servers, S3 primary storage, Redis, database replicas. For very large setups consider OpenCloud, which scales more easily | 4 to 6 app servers |
| Caddy | several instances behind DNS round-robin or a load balancer, with shared certificate storage, or replace it with HAProxy | 2 |
| sync | one instance is enough; it pages through users 500 at a time | 1 |

**Light users** (e.g. 100,000 students) mostly use mail and sometimes files:
- Give them smaller quotas in Stalwart and Nextcloud.
- To give mailboxes only to some groups, use `MAIL_GROUP`.
- Keycloak handles 110,000 users without problems; import them from AD with pagination (already on).

**Multi-host with this repo:**
- Put the hosts into separate inventory groups and copy each `office/<service>` folder to its host.
- Replace container names with host names: Caddy upstreams, `postgres` in the configs, URLs in `sync.py`.

## 7. Adapting: other software

Each folder is one function. To use another product, replace the folder contents. The replacement must:
1. accept Keycloak access tokens as bearer tokens (or SASL), with the audience of the function;
2. use the `email` claim as the user;
3. get a block in `proxy/Caddyfile`;
4. get a target class in `sync/sync.py` (or speak SCIM).

| Function | Alternatives |
|---|---|
| Chat | **Matrix**: Synapse with Matrix Authentication Service (upstream OIDC to Keycloak); Element Call also uses LiveKit |
| Meetings | **OpenTalk** (uses Keycloak and LiveKit natively); **La Suite Meet** (OIDC, LiveKit, MIT license); **Jitsi Meet** (JWT) |
| Files | **OpenCloud**: env `OC_OIDC_ISSUER`, `PROXY_AUTOPROVISION_ACCOUNTS=true`, `PROXY_OIDC_ACCESS_TOKEN_VERIFY_METHOD=jwt`, `PROXY_OIDC_AUDIENCES=files`; bearer tokens work on WebDAV; no SCIM, deprovision via its Graph API. **Stalwart**: already serves WebDAV files at `https://mail.DOMAIN/dav/file/` and JMAP FileNode, so no extra service is needed |
| Mail | any server that accepts OAUTHBEARER and validates Keycloak JWTs |
| Login | any OpenID Connect provider with JWT access tokens and audience mappers |
| Reverse proxy | Traefik, nginx, HAProxy |
| DNS | any DNSControl provider, or enter the zone file by hand |

## 8. Security and operations

- **Secrets:** `/opt/office/.env` (mode 600), generated on the first run. Back it up.
- **Backups:** everything is under `/opt/office`:
  - `*/data`: database, mail blobs, files, certificates
  - `.env`
  - `mail/dkim.key`
  - also take regular `pg_dumpall` dumps
- **Open ports:**
  - 80, 443 (Caddy)
  - 25, 465, 587, 993 (Stalwart)
  - 7881/tcp, 7882/udp, 3478/udp (LiveKit)
  - nothing else
- **Admin access:**
  - The Keycloak admin console is only reachable from `ADMIN_NETWORKS`.
  - Stalwart's recovery admin (`STALWART_ADMIN_PASSWORD`) is the break-glass account and the account used by `setup.sh` and `sync`.
- **Certificates:** Caddy gets and renews all of them. `mail/reload-cert.sh` (daily cron) makes Stalwart load the renewed one.
- **Logs:** `docker logs <container>`.

## 9. Not included (yet)

- **Web clients:**
  - Webmail: Stalwart has none. Options: Roundcube with OAuth2, or a JMAP web client.
  - A meetings web app: La Suite Meet, or your own.
- **Federation:** chat (XMPP s2s) is not set up. It needs ejabberd's TCP ports and certificates.
- **TURN over TLS on port 443**, for very restrictive networks: needs a second IP address or an L4 proxy.
- **Mobile chat push notifications** (`mod_push` plus a push service).
- **Mail extras:** MTA-STS, TLS-RPT, DANE, and spam and virus filter tuning (Stalwart's spam filter is on by default).
- **Keycloak key rotation:** after rotating keys, run `chat/setup.sh` again (ejabberd needs the new key).

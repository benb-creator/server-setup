# Mail and collaboration server: blueprint

Mail, calendar, contacts, chat, video meetings and files for one organization (company,
government office, university). All open source, on premises, in Docker, with one login
for everything.

| | Software | Clients use |
|---|---|---|
| Login | Keycloak | OAuth2 / OpenID Connect. Users are local, from Active Directory, or both. Windows SSO via Kerberos |
| Mail, calendar, contacts | Stalwart | JMAP (also IMAP, SMTP, CalDAV, CardDAV) |
| Chat | ejabberd | XMPP over WebSocket |
| Meetings | LiveKit | WebRTC |
| Files | Nextcloud | WebDAV |

Clients log in once at Keycloak and use the OAuth2 access token with every service.
Accounts are created on demand. Mailboxes are created in advance, so mail can arrive
before the first login. Disabling or deleting a user in Keycloak or AD reaches every
service within minutes.

## Quick start: everything in one go

You need:
- a Linux server with Docker (`docker compose`) and a public IP, reachable via SSH;
- Ansible on your computer (`pipx install ansible-core`).

```bash
git clone https://github.com/benb-creator/server-setup.git && cd server-setup
```

```bash
./setup.sh example.com root@203.0.113.10 CLOUDFLAREAPI apitoken=YOUR_TOKEN
```

The arguments are your domain, the server's SSH login, and your DNS provider with its login.
- The provider types are listed in DNSControl's provider list (https://docs.dnscontrol.org/provider/index).
- Leave out the DNS part to get only a zone file, which you then enter yourself.

Then:
1. Open `https://auth.example.com/admin/` (user `admin`, password in `/opt/office/.env` on the server).
2. Create users in realm `office`, or connect AD (TODO.md step 7b).
3. Run `/opt/office/test.sh` to check every service.

## Documents

- **[PLAN.md](PLAN.md)**: architecture, how login and provisioning work, split mail domains, DNS, scaling to 30,000+ users, alternatives (Matrix, OpenCloud, OpenTalk, ...).
- **[TODO.md](TODO.md)**: step-by-step manual setup, one service at a time, about 30 minutes.

## Layout

```
setup.sh                one-shot setup: writes inventory.yml, runs site.yml
site.yml                Ansible playbook, does the same steps as TODO.md
inventory.example.yml   inventory with all options
office/                 copied to /opt/office on the server
  .env.example          ALL settings: domain, host names, options, secrets
  test.sh               logs in (device flow) and checks every service
  postgres/             database for Keycloak, Stalwart, Nextcloud, ejabberd
  proxy/                Caddy: HTTPS and certificates for all web services
  auth/                 Keycloak: realm.json (clients), ad.sh (Active Directory, Kerberos)
  mail/                 Stalwart: setup.sh holds its settings, reload-cert.sh
  chat/                 ejabberd: ejabberd.yml
  meet/                 LiveKit, plus meet-token.py (Keycloak token → room token)
  files/                Nextcloud: setup.sh connects it to Keycloak
  sync/                 sync.py: creates, disables and deletes accounts, with SCIM where possible
  dns/                  dnsconfig.js: all DNS records; dns.sh writes the zone file and updates your DNS provider
```

Each service folder has a `compose.yml`, at most one small config file, and a `setup.sh`
if it needs more than `docker compose up -d`. All folders read `office/.env`.

## Adapting

- **Settings:** host names, split mail domain, mailbox group, deletion policy, AD: all in `office/.env`.
- **Another product:** replace its folder. PLAN.md section 7 lists what a replacement must do, and the alternatives.
- **Several servers:** each folder can run on its own host (PLAN.md section 6).
- **Changes with Ansible:** edit the files here and run `./setup.sh` again. It copies `office/` over `/opt/office`. Settings already in `/opt/office/.env` and all data stay.
- **Changes by hand:** edit the files in `/opt/office`, then run the folder's `setup.sh` (or `docker compose up -d`).

## Versions tested

Keycloak 26.8, Stalwart 1.1, ejabberd 26.09, LiveKit 1.13, Nextcloud 34, PostgreSQL 18,
Caddy 2, DNSControl 5.10 (November 2026).

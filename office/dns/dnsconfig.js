// DNS records for all services, for DNSControl. dns.sh fills in the variables from ../.env.
// Writes zones/<domain>.zone. With a "dns" entry in creds.json it also updates your DNS provider.

var MAIL = mail_host + ".";
function HOST(name) { return ip6 ? [A(name, ip4), AAAA(name, ip6)] : [A(name, ip4)]; }

D(domain, REGISTRAR(),
  provider ? [SERVICE("dns")] : [],   // your DNS provider, from creds.json
  SERVICE("bind", 0),                 // the zone file
  NO_PURGE,                           // never delete records that are not listed here

  // Host names of the services, all on this server
  HOST(auth_host + "."), HOST(mail_host + "."), HOST(chat_host + "."), HOST(meet_host + "."), HOST(files_host + "."),
  HOST("autoconfig"), HOST("autodiscover"),

  // DKIM public key; the private key is mail/dkim.key
  TXT(selector + "._domainkey", "v=DKIM1; k=rsa; p=" + dkim),

  // Service discovery for mail, calendar and contacts clients (RFC 6186, 8314, 6764, 8620)
  SRV("_submissions._tcp", 0, 1, 465, MAIL),
  SRV("_submission._tcp", 0, 1, 587, MAIL),
  SRV("_imaps._tcp", 0, 1, 993, MAIL),
  SRV("_jmap._tcp", 0, 1, 443, MAIL),
  SRV("_caldavs._tcp", 0, 1, 443, MAIL),
  SRV("_carddavs._tcp", 0, 1, 443, MAIL),

  // Mail routing and policy. These replace existing records of the same name, so only with mail_records=yes.
  mail_records == "yes" ? [
    MX("@", 10, MAIL),
    TXT("@", "v=spf1 mx -all"),
    TXT("_dmarc", "v=DMARC1; p=quarantine"),
  ] : []
);

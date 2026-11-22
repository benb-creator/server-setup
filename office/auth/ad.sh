#!/bin/sh
# Optional: connects Keycloak to Active Directory (users, groups, account disable) and Windows SSO (Kerberos).
# Needs the AD_* settings in .env. For SSO also kerberos/keycloak.keytab (see TODO.md). Run once.
set -e
cd "$(dirname "$0")"
. ./.env
kc() { docker exec keycloak /opt/keycloak/bin/kcadm.sh "$@"; }
kc config credentials --server http://localhost:8080 --realm master --user admin --password "$KEYCLOAK_ADMIN_PASSWORD"

if [ -n "$(kc get components -r "$REALM" -q name=ad --fields id --format csv)" ]; then
  echo "AD connection exists already; change it in the admin console (User federation > ad)."; exit 0
fi

# Kerberos (Windows SSO) only if a keytab is there
kerberos=false
if [ -n "$AD_KERBEROS_REALM" ] && [ -f kerberos/keycloak.keytab ]; then
  kerberos=true
  printf '[libdefaults]\n  default_realm = %s\n  dns_lookup_kdc = true\n' "$AD_KERBEROS_REALM" > kerberos/krb5.conf
fi

# Read-only AD connection; users are imported, changes are synced every 5 minutes
kc create components -r "$REALM" -s name=ad -s providerId=ldap -s providerType=org.keycloak.storage.UserStorageProvider \
  -s 'config.vendor=["ad"]' -s 'config.editMode=["READ_ONLY"]' -s 'config.importEnabled=["true"]' \
  -s "config.connectionUrl=[\"$AD_URL\"]" -s "config.usersDn=[\"$AD_USERS_DN\"]" -s 'config.searchScope=["2"]' \
  -s "config.bindDn=[\"$AD_BIND_DN\"]" -s "config.bindCredential=[\"$AD_BIND_PASSWORD\"]" -s 'config.authType=["simple"]' \
  -s 'config.usernameLDAPAttribute=["sAMAccountName"]' -s 'config.rdnLDAPAttribute=["cn"]' \
  -s 'config.uuidLDAPAttribute=["objectGUID"]' -s 'config.userObjectClasses=["person, organizationalPerson, user"]' \
  -s 'config.changedSyncPeriod=["300"]' -s 'config.fullSyncPeriod=["86400"]' \
  -s "config.allowKerberosAuthentication=[\"$kerberos\"]" -s "config.kerberosRealm=[\"$AD_KERBEROS_REALM\"]" \
  -s "config.serverPrincipal=[\"HTTP/$AUTH_HOST@$AD_KERBEROS_REALM\"]" \
  -s 'config.keyTab=["/opt/keycloak/conf/kerberos/keycloak.keytab"]' -s 'config.krbPrincipalAttribute=["userPrincipalName"]'

# Import all AD users now
id=$(kc get components -r "$REALM" -q name=ad --fields id --format csv --noquotes)
kc create "user-storage/$id/sync?action=triggerFullSync" -r "$REALM"
[ "$kerberos" = true ] && docker restart keycloak    # reads krb5.conf at start
echo "Done. Kerberos SSO: $kerberos"

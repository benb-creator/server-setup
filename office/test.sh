#!/bin/sh
# Logs in as a user (in your browser, device flow) and checks that every service accepts the token.
# Run on the server after setup:  ./test.sh
set -e
cd "$(dirname "$0")"
. ./.env

if [ -z "$TOKEN" ]; then
  device=$(curl -fsS -d client_id=office -d scope=openid "$ISSUER/protocol/openid-connect/auth/device")
  echo "Open $(echo "$device" | jq -r .verification_uri_complete) and log in as a test user."
  code=$(echo "$device" | jq -r .device_code)
  until TOKEN=$(curl -fsS -d client_id=office -d grant_type=urn:ietf:params:oauth:grant-type:device_code \
      -d device_code="$code" "$ISSUER/protocol/openid-connect/token" 2>/dev/null | jq -er .access_token); do sleep 5; done
fi
email=$(curl -fsS -H "Authorization: Bearer $TOKEN" "$ISSUER/protocol/openid-connect/userinfo" | jq -r .email)
echo "Logged in as $email"

# check NAME EXPECTED-HTTP-CODE CURL-ARGS...
check() {
  name=$1 expected=$2; shift 2
  got=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$@")
  [ "$got" = "$expected" ] && result=ok || result="FAILED (HTTP $got)"
  printf '%-34s %s\n' "$name" "$result"
}
check "Mail: JMAP session" 200 "https://$MAIL_HOST/jmap/session"
check "Calendar: CalDAV" 207 -X PROPFIND -H "Depth: 0" "https://$MAIL_HOST/dav/cal/"
check "Contacts: CardDAV" 207 -X PROPFIND -H "Depth: 0" "https://$MAIL_HOST/dav/card/"
check "Files: WebDAV" 207 -X PROPFIND -H "Depth: 0" "https://$FILES_HOST/remote.php/dav/files/$email/"
check "Meet: room token" 200 -X POST -d '{"room":"test"}' "https://$MEET_HOST/token"
check "Chat: XMPP discovery" 200 "https://$CHAT_HOST/.well-known/host-meta"
echo "Chat login: use an XMPP client with wss://$CHAT_HOST/xmpp-websocket, user $email, the token as password."

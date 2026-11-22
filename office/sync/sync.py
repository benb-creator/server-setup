"""Keeps the app accounts in line with Keycloak, the source of truth for users.

Runs every SYNC_INTERVAL seconds, and right away on any POST to port 8080 (e.g. a Keycloak webhook).
Users are matched by email address. Targets (SYNC_TARGETS):
  stalwart   creates mailboxes (mail must arrive before the first login), suspends, deletes
  nextcloud  disables, re-enables, deletes (accounts are created at first login)
  ejabberd   disconnects disabled users; deletes chat data of removed users (no accounts with token login)
  scim       any SCIM 2.0 server in SCIM_TARGETS: creates, deactivates, re-activates, deletes
Deletion only with SYNC_DELETE=true; otherwise removed users are disabled.
"""
import base64
import json
import os
import threading
import time
import traceback
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

env = os.environ.get
DOMAIN = env("DOMAIN")
DELETE = env("SYNC_DELETE", "false") == "true"
STATE = "/data/users.json"  # users seen last time, to notice removals


def http(method, url, body=None, auth=None, form=None, content_type="application/json", headers=None):
    """Sends a request and returns the decoded JSON response (or None)."""
    headers = {"Accept": "application/json", **(headers or {})}
    if auth:
        headers["Authorization"] = auth
    data = None
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
    elif body is not None:
        data, headers["Content-Type"] = json.dumps(body).encode(), content_type
    request = urllib.request.Request(url, data, headers, method=method)
    with urllib.request.urlopen(request, timeout=60) as response:
        text = response.read()
    return json.loads(text) if text else None


def basic(user, password):
    return "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()


def keycloak_users():
    """Returns {email: {"id", "name", "enabled", "mail"}} for all Keycloak users with an email address."""
    base = f"{env('KEYCLOAK_URL')}/realms/{env('REALM')}"
    token = http("POST", f"{base}/protocol/openid-connect/token",
                 form={"grant_type": "client_credentials", "client_id": "sync", "client_secret": env("SYNC_CLIENT_SECRET")})
    admin = f"{env('KEYCLOAK_URL')}/admin/realms/{env('REALM')}"
    get = lambda path: http("GET", f"{admin}/{path}", auth="Bearer " + token["access_token"])

    def paged(path):
        first = 0
        while batch := get(f"{path}{'&' if '?' in path else '?'}briefRepresentation=true&first={first}&max=500"):
            yield from batch
            first += len(batch)

    users = {}
    for u in paged("users"):
        if u.get("email"):
            name = " ".join(filter(None, [u.get("firstName"), u.get("lastName")]))
            users[u["email"].lower()] = {"id": u["id"], "name": name, "enabled": u["enabled"], "mail": True}
    if env("MAIL_GROUP"):  # only group members get a mailbox
        groups = [g for g in get(f"groups?search={urllib.parse.quote(env('MAIL_GROUP'))}&exact=true") if g["name"] == env("MAIL_GROUP")]
        members = {m["email"].lower() for g in groups for m in paged(f"groups/{g['id']}/members") if m.get("email")}
        for email, u in users.items():
            u["mail"] = email in members
    return users


class Stalwart:
    """Stalwart management API (JMAP). Mailboxes it creates carry the Keycloak user id as externalId."""
    url, auth = "http://stalwart:8080/jmap/", basic("admin", env("STALWART_ADMIN_PASSWORD"))
    suspended = {"@type": "Merge", "enabledPermissions": {}, "disabledPermissions": {"authenticate": True, "emailSend": True}}

    def call(self, method, args):
        body = {"using": ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"], "methodCalls": [[method, args, "0"]]}
        name, result, _ = http("POST", self.url, body, self.auth)["methodResponses"][0]
        if name == "error" or result.get("notCreated") or result.get("notUpdated") or result.get("notDestroyed"):
            raise RuntimeError(f"{method}: {result}")
        return result

    def accounts(self):
        ids, position = [], 0
        while batch := self.call("x:Account/query", {"position": position, "limit": 500})["ids"]:
            ids += batch
            position += len(batch)
        accounts = {}
        for i in range(0, len(ids), 500):
            for a in self.call("x:Account/get", {"ids": ids[i:i + 500]})["list"]:
                if a["@type"] == "User":
                    accounts[a["emailAddress"].lower()] = a
        return accounts

    def sync(self, users):
        domain_id = self.call("x:Domain/query", {"filter": {"name": DOMAIN}})["ids"][0]
        accounts = self.accounts()
        for email, u in users.items():
            account = accounts.get(email)
            wanted = u["mail"] and u["enabled"] and email.endswith("@" + DOMAIN)
            if wanted and not account:
                print("stalwart: create", email)
                self.call("x:Account/set", {"create": {"new": {"@type": "User", "name": email.split("@")[0], "domainId": domain_id,
                                                               "description": u["name"], "externalId": u["id"]}}})
            elif account and not account.get("externalId"):  # created at first login: adopt it
                self.call("x:Account/set", {"update": {account["id"]: {"externalId": u["id"]}}})
        for email, account in accounts.items():
            if not account.get("externalId"):
                continue  # not ours, e.g. a shared mailbox
            u = users.get(email)
            if not u and DELETE:
                print("stalwart: delete", email)
                self.call("x:Account/set", {"destroy": [account["id"]]})
            else:
                active = bool(u and u["enabled"] and u["mail"])
                if active != (account["permissions"] != self.suspended):
                    print("stalwart:", "enable" if active else "suspend", email)
                    permissions = {"@type": "Inherit"} if active else self.suspended
                    self.call("x:Account/set", {"update": {account["id"]: {"permissions": permissions}}})


class Nextcloud:
    """Nextcloud OCS provisioning API. Touches only accounts created by Keycloak login (backend user_oidc)."""
    url, auth = f"https://{env('FILES_HOST')}/ocs/v2.php/cloud/users", basic("admin", env("NEXTCLOUD_ADMIN_PASSWORD"))

    def ocs(self, method, path=""):
        return http(method, f"{self.url}{path}{'&' if '?' in path else '?'}format=json", auth=self.auth,
                    headers={"OCS-APIRequest": "true"})

    def sync(self, users):
        offset = 0
        while batch := self.ocs("GET", f"/details?limit=500&offset={offset}")["ocs"]["data"]["users"]:
            offset += len(batch)
            for uid, account in batch.items():
                if account.get("backend") != "user_oidc":
                    continue
                u = users.get(uid.lower())
                if not u and DELETE:
                    print("nextcloud: delete", uid)
                    self.ocs("DELETE", f"/{urllib.parse.quote(uid)}")
                elif bool(u and u["enabled"]) != account["enabled"]:
                    action = "enable" if u and u["enabled"] else "disable"
                    print("nextcloud:", action, uid)
                    self.ocs("PUT", f"/{urllib.parse.quote(uid)}/{action}")


class Ejabberd:
    """ejabberd API. Token login means no accounts: disconnect disabled users, purge removed ones."""
    url = "http://ejabberd:5281/api/"

    def call(self, command, **args):
        return http("POST", self.url + command, args)

    def sync(self, users):
        for jid in {j.split("/")[0].lower() for j in self.call("connected_users")}:
            if not (users.get(jid) or {}).get("enabled"):
                print("ejabberd: kick", jid)
                self.call("kick_user", user=jid.split("@")[0], host=jid.split("@")[1])

    def removed(self, emails):
        for email in emails if DELETE else []:
            print("ejabberd: unregister", email)
            self.call("unregister", user=email.split("@")[0], host=email.split("@")[1])


class Scim:
    """Any SCIM 2.0 server: full provisioning, as SCIM intends."""
    def __init__(self, url, token):
        self.url, self.auth = url.rstrip("/"), "Bearer " + token

    def scim(self, method, path, body=None):
        return http(method, self.url + path, body, self.auth, content_type="application/scim+json")

    def sync(self, users):
        accounts, start = {}, 1
        while batch := self.scim("GET", f"/Users?startIndex={start}&count=200").get("Resources"):
            accounts.update({a["userName"].lower(): a for a in batch})
            start += len(batch)
        for email, u in users.items():
            if u["enabled"] and email not in accounts:
                print("scim: create", email, "at", self.url)
                self.scim("POST", "/Users", {"schemas": ["urn:ietf:params:scim:schemas:core:2.0:User"], "userName": email,
                                             "externalId": u["id"], "displayName": u["name"], "active": True,
                                             "emails": [{"value": email, "primary": True}]})
        for email, account in accounts.items():
            u = users.get(email)
            if not u and DELETE:
                print("scim: delete", email, "at", self.url)
                self.scim("DELETE", f"/Users/{account['id']}")
            elif bool(u and u["enabled"]) != account.get("active", True):
                self.scim("PATCH", f"/Users/{account['id']}", {"schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
                          "Operations": [{"op": "replace", "path": "active", "value": bool(u and u["enabled"])}]})


def targets():
    names = env("SYNC_TARGETS", "stalwart nextcloud ejabberd").split()
    found = [{"stalwart": Stalwart, "nextcloud": Nextcloud, "ejabberd": Ejabberd}[n]() for n in names if n != "scim"]
    if "scim" in names:  # SCIM_TARGETS="https://app1/scim/v2|token1 https://app2/scim/v2|token2"
        found += [Scim(*t.split("|", 1)) for t in env("SCIM_TARGETS", "").split()]
    return found


def sync_once():
    users = keycloak_users()
    if not users:
        return print("Keycloak returned no users; skipping, to be safe")
    seen = set(json.load(open(STATE))) if os.path.exists(STATE) else set(users)
    for target in targets():
        try:
            target.sync(users)
            if hasattr(target, "removed"):
                target.removed(seen - set(users))
        except Exception:
            traceback.print_exc()
    json.dump(sorted(users), open(STATE, "w"))


wake = threading.Event()


class Trigger(BaseHTTPRequestHandler):
    def do_POST(self):  # any POST, e.g. from a Keycloak event webhook, starts a sync now
        wake.set()
        self.send_response(202)
        self.end_headers()


threading.Thread(target=ThreadingHTTPServer(("", 8080), Trigger).serve_forever, daemon=True).start()
while True:
    try:
        sync_once()
    except Exception:
        traceback.print_exc()
    wake.wait(int(env("SYNC_INTERVAL", "300")))
    wake.clear()

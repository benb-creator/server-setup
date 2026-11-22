"""Swaps a Keycloak access token for a LiveKit room token.

POST /token  {"room": "team-weekly"}   Authorization: Bearer <Keycloak access token>
  -> 200 {"url": "wss://meet.example.com", "token": "<LiveKit token>"}
"""
import base64
import hashlib
import hmac
import json
import os
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ISSUER = os.environ["ISSUER"]  # https://auth.example.com/realms/office
LIVEKIT_URL = os.environ["LIVEKIT_URL"]  # wss://meet.example.com
API_KEY, API_SECRET = os.environ["LIVEKIT_API_KEY"], os.environ["LIVEKIT_API_SECRET"]


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def keycloak_user(bearer):
    """Asks Keycloak whether the token is valid (and the user still active); returns the user's claims."""
    request = urllib.request.Request(ISSUER + "/protocol/openid-connect/userinfo", headers={"Authorization": "Bearer " + bearer})
    with urllib.request.urlopen(request, timeout=10) as response:
        user = json.load(response)
    audience = json.loads(base64.urlsafe_b64decode(bearer.split(".")[1] + "==")).get("aud", [])
    if "meet" not in audience:  # token must be meant for us (audience mapper in auth/realm.json)
        raise PermissionError("wrong audience")
    return user


def livekit_token(user, room):
    now = int(time.time())
    claims = {"iss": API_KEY, "sub": user["email"], "name": user.get("name", user["email"]),
              "nbf": now, "exp": now + 6 * 3600, "video": {"roomJoin": True, "room": room}}
    signed = b64(b'{"alg":"HS256","typ":"JWT"}') + "." + b64(json.dumps(claims).encode())
    return signed + "." + b64(hmac.new(API_SECRET.encode(), signed.encode(), hashlib.sha256).digest())


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            user = keycloak_user(self.headers.get("Authorization", "").removeprefix("Bearer "))
        except Exception:
            return self.reply(401, {"error": "invalid or expired token"})
        length = int(self.headers.get("Content-Length") or 0)
        room = str(json.loads(self.rfile.read(length) or b"{}").get("room", "")).strip()
        if not room:
            return self.reply(400, {"error": "room missing"})
        self.reply(200, {"url": LIVEKIT_URL, "token": livekit_token(user, room)})

    def do_OPTIONS(self):  # CORS preflight for web apps
        self.reply(204, None)

    def reply(self, status, data):
        self.send_response(status)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        if data is not None:
            self.wfile.write(json.dumps(data).encode())


ThreadingHTTPServer(("", 8000), Handler).serve_forever()

#!/usr/bin/env python3
"""Token service for the Nginx/Zot auth proxy.

Implements the Docker Registry v2 token flow, backed by Keystone application
credentials:

  * GET  /auth/token     — Basic(app_id:app_secret) -> signed JWT (RS256)
  * GET  /auth/validate  — called by Nginx auth_request; verifies the JWT
                           *and* that its `access` claim covers the repository
                           and action of the original request.

Installed by 08_auth_proxy_install.sh (and only there — this file is the single
source of truth; 10_registry_smoke_test.sh must not rewrite it).
"""

import base64
import fnmatch
import json
import os
import re
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEYSTONE_URL = os.environ["KEYSTONE_URL"]
PRIVATE_KEY = "/etc/auth-proxy/jwt.key"
PUBLIC_KEY = "/etc/zot/jwt.pub"
SERVICE_NAME = "zot-registry"
ISSUER = "auth-proxy"
TOKEN_TTL = 3600

# Optional comma-separated glob allowlist (e.g. "my-app,demo-app,rancher/*").
# Empty means "any repository in this project" — the credential is still
# validated by Keystone, but repository-level authorisation is project-wide.
ALLOWED_REPOS = [p for p in os.environ.get("ALLOWED_REPOS", "").split(",") if p]

# /v2/<name>/{manifests,blobs,tags,referrers}/...  — <name> may contain slashes.
REPO_URI = re.compile(r"^/v2/(.+)/(?:manifests|blobs|tags|referrers)/")
WRITE_METHODS = {"PUT", "POST", "PATCH", "DELETE"}
VALID_ACTIONS = {"pull", "push"}


def b64d(data):
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


def b64e(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def jwt_sign(payload):
    header = {"alg": "RS256", "typ": "JWT"}
    signing_input = b64e(json.dumps(header).encode()) + "." + b64e(json.dumps(payload).encode())
    proc = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", PRIVATE_KEY],
        input=signing_input.encode(), capture_output=True, check=True,
    )
    return signing_input + "." + b64e(proc.stdout)


def jwt_verify(token):
    """Return the payload if the RS256 signature is valid, else None."""
    parts = token.split(".")
    if len(parts) != 3:
        return None
    signing_input = (parts[0] + "." + parts[1]).encode()
    try:
        signature = b64d(parts[2])
    except Exception:
        return None
    with tempfile.NamedTemporaryFile(delete=False) as sig_file:
        sig_file.write(signature)
        sig_path = sig_file.name
    try:
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", PUBLIC_KEY, "-signature", sig_path],
            input=signing_input, capture_output=True,
        )
    finally:
        os.unlink(sig_path)
    if proc.returncode != 0:
        return None
    try:
        return json.loads(b64d(parts[1]))
    except Exception:
        return None


def repo_from_uri(uri):
    match = REPO_URI.match(uri or "")
    return match.group(1) if match else None


def authorize(auth_header, method, uri):
    """Full authorisation check for an incoming registry request.

    Returns (allowed, reason). Signature + aud/iss/exp are always required;
    repository endpoints additionally require a matching `access` entry.
    """
    if not auth_header or not auth_header.startswith("Bearer "):
        return False, "no bearer token"
    payload = jwt_verify(auth_header[7:])
    if payload is None:
        return False, "bad signature"

    now = time.time()
    if payload.get("iss") != ISSUER:
        return False, f"bad issuer {payload.get('iss')!r}"
    if payload.get("aud") != SERVICE_NAME:
        return False, f"bad audience {payload.get('aud')!r}"
    if payload.get("nbf", 0) > now:
        return False, "token not yet valid"
    if payload.get("exp", 0) < now:
        return False, "token expired"

    repo = repo_from_uri(uri)
    if repo is None:
        # /v2/ ping, _catalog, etc. — a valid token is enough; no repo scope.
        return True, "ok (unscoped)"

    action = "push" if (method or "GET").upper() in WRITE_METHODS else "pull"
    for entry in payload.get("access") or []:
        if entry.get("type") != "repository" or entry.get("name") != repo:
            continue
        actions = entry.get("actions") or []
        if "*" in actions or action in actions:
            return True, f"ok ({action} {repo})"
        # A push grant implies pull; the reverse is not true.
        if action == "pull" and "push" in actions:
            return True, f"ok (pull via push {repo})"
    return False, f"scope does not grant {action} on {repo!r}"


def parse_scopes(values):
    """Parse ?scope=repository:<name>:<actions> into access entries.

    Returns None on malformed input so the caller can answer 400 instead of
    crashing (the previous code indexed split() blindly and raised IndexError).
    """
    access = []
    for raw in values:
        for piece in raw.split():
            parts = piece.split(":")
            if len(parts) != 3 or parts[0] != "repository" or not parts[1]:
                return None
            actions = [a for a in parts[2].split(",") if a]
            if not actions or any(a not in VALID_ACTIONS for a in actions):
                return None
            if ALLOWED_REPOS and not any(fnmatch.fnmatch(parts[1], p) for p in ALLOWED_REPOS):
                return None
            access.append({
                "type": "repository",
                "name": parts[1],
                "actions": sorted(set(actions)),
            })
    return access


class TokenHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        self.do_GET()

    def do_GET(self):
        if self.path.startswith("/auth/validate"):
            auth_header = self.headers.get("Authorization", "")
            method = self.headers.get("X-Original-Method", "GET")
            uri = self.headers.get("X-Original-URI", "")
            allowed, reason = authorize(auth_header, method, uri)
            if not allowed:
                print(f"[token-service] deny {method} {uri}: {reason}", flush=True)
                self._reply(401, b"")
                return
            self._reply(200, b"")

        elif self.path.startswith("/auth/token"):
            self._issue_token()

        else:
            self._reply(404, b"")

    def _issue_token(self):
        auth_header = self.headers.get("Authorization", "")
        if not auth_header.startswith("Basic "):
            self._reply(401, b"", {"WWW-Authenticate": 'Basic realm="Keystone"'})
            return
        try:
            cred_raw = base64.b64decode(auth_header[6:]).decode()
        except Exception:
            self._reply(400, b"")
            return
        if ":" not in cred_raw:
            self._reply(400, b"")
            return
        app_id, app_secret = cred_raw.split(":", 1)

        # The credential must be a real Keystone application credential.
        body = json.dumps({
            "auth": {"identity": {
                "methods": ["application_credential"],
                "application_credential": {"id": app_id, "secret": app_secret},
            }}
        }).encode()
        req = urllib.request.Request(
            f"{KEYSTONE_URL}/auth/tokens", data=body,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        try:
            with urllib.request.urlopen(req) as resp:
                if resp.status != 201:
                    raise RuntimeError(f"Keystone returned {resp.status}")
        except urllib.error.HTTPError as exc:
            print(f"[token-service] Keystone auth failed: HTTP {exc.code}", flush=True)
            self._reply(401, b"")
            return
        except Exception as exc:
            print(f"[token-service] Keystone error: {exc}", flush=True)
            self._reply(401, b"")
            return

        params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        access = parse_scopes(params.get("scope", []))
        if access is None:
            print("[token-service] rejected malformed scope: "
                  f"{params.get('scope')}", flush=True)
            self._reply(400, b'{"errors":[{"code":"DENIED","message":"invalid scope"}]}')
            return

        now = int(time.time())
        token = jwt_sign({
            "iss": ISSUER, "sub": app_id, "aud": SERVICE_NAME,
            "iat": now, "nbf": now, "exp": now + TOKEN_TTL,
            "access": access,
        })
        self._reply(200, json.dumps({
            "token": token, "access_token": token, "expires_in": TOKEN_TTL,
        }).encode(), {"Content-Type": "application/json"})

    def _reply(self, code, body, headers=None):
        self.send_response(code)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, fmt, *args):
        print(f"[token-service] {fmt % args}", flush=True)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 5001), TokenHandler).serve_forever()

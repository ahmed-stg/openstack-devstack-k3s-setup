#!/usr/bin/env python3
"""Tests for lib/token_service.py — no lab, no network, no Keystone needed.

Run:
    python3 -m unittest discover -s tests -v
    make test

Covers the two halves of the service:
  * the pure authorisation logic (scope parsing, JWT claims, repository
    matching) — the part that decides whether a request is allowed;
  * the HTTP surface (token issue, auth_request validation, containerd's POST).
"""

import base64
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = pathlib.Path(__file__).resolve().parents[1]
os.environ.setdefault("KEYSTONE_URL", "http://127.0.0.1:1")

_spec = importlib.util.spec_from_file_location("token_service", ROOT / "lib" / "token_service.py")
ts = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ts)


def bearer(token):
    return {"Authorization": f"Bearer {token}"}


class TestPureLogic(unittest.TestCase):
    """Scope parsing, URI parsing and JWT claim validation."""

    @classmethod
    def setUpClass(cls):
        cls.keydir = tempfile.mkdtemp(prefix="token-test-")
        cls.key = pathlib.Path(cls.keydir) / "jwt.key"
        cls.pub = pathlib.Path(cls.keydir) / "jwt.pub"
        subprocess.run(["openssl", "genrsa", "-out", str(cls.key), "2048"],
                       check=True, capture_output=True)
        subprocess.run(["openssl", "rsa", "-in", str(cls.key), "-pubout", "-out", str(cls.pub)],
                       check=True, capture_output=True)
        ts.PRIVATE_KEY = str(cls.key)
        ts.PUBLIC_KEY = str(cls.pub)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.keydir, ignore_errors=True)

    def setUp(self):
        self._allowed = ts.ALLOWED_REPOS
        ts.ALLOWED_REPOS = []

    def tearDown(self):
        ts.ALLOWED_REPOS = self._allowed

    def mint(self, access=None, **claims):
        now = int(time.time())
        payload = {
            "iss": ts.ISSUER,
            "sub": "app-credential",
            "aud": ts.SERVICE_NAME,
            "iat": now,
            "nbf": now,
            "exp": now + 60,
            "access": access or [],
        }
        payload.update(claims)
        return ts.jwt_sign(payload)

    # -- base64 helpers ---------------------------------------------------
    def test_b64_roundtrip(self):
        self.assertEqual(ts.b64d(ts.b64e(b"hello")), b"hello")

    def test_b64d_accepts_missing_padding(self):
        self.assertEqual(ts.b64d(ts.b64e(b"a")), b"a")
        self.assertEqual(ts.b64d(ts.b64e(b"ab")), b"ab")

    # -- repository extraction from /v2/<name>/... ------------------------
    def test_repo_from_manifests_uri(self):
        self.assertEqual(ts.repo_from_uri("/v2/my-app/manifests/v1"), "my-app")

    def test_repo_from_blobs_uri(self):
        self.assertEqual(ts.repo_from_uri("/v2/my-app/blobs/sha256:abc"), "my-app")

    def test_repo_from_tags_uri(self):
        self.assertEqual(ts.repo_from_uri("/v2/my-app/tags/list"), "my-app")

    def test_repo_from_nested_name(self):
        self.assertEqual(
            ts.repo_from_uri("/v2/rancher/mirrored-pause/manifests/3.6"),
            "rancher/mirrored-pause",
        )

    def test_repo_from_ping_is_none(self):
        self.assertIsNone(ts.repo_from_uri("/v2/"))

    def test_repo_from_catalog_is_none(self):
        self.assertIsNone(ts.repo_from_uri("/v2/_catalog"))

    # -- scope parsing ----------------------------------------------------
    def test_parse_scopes_single_pull(self):
        self.assertEqual(
            ts.parse_scopes(["repository:my-app:pull"]),
            [{"type": "repository", "name": "my-app", "actions": ["pull"]}],
        )

    def test_parse_scopes_dedupes_and_sorts_actions(self):
        self.assertEqual(
            ts.parse_scopes(["repository:my-app:push,pull,push"])[0]["actions"],
            ["pull", "push"],
        )

    def test_parse_scopes_multiple_values(self):
        parsed = ts.parse_scopes(["repository:my-app:pull", "repository:demo-app:push"])
        self.assertEqual([p["name"] for p in parsed], ["my-app", "demo-app"])

    def test_parse_scopes_multiple_space_separated(self):
        parsed = ts.parse_scopes(["repository:a:pull repository:b:push"])
        self.assertEqual(len(parsed), 2)

    def test_parse_scopes_rejects_missing_fields(self):
        self.assertIsNone(ts.parse_scopes(["repository:my-app"]))

    def test_parse_scopes_rejects_unknown_action(self):
        self.assertIsNone(ts.parse_scopes(["repository:my-app:delete"]))

    def test_parse_scopes_rejects_empty_repo(self):
        self.assertIsNone(ts.parse_scopes(["repository::pull"]))

    def test_parse_scopes_rejects_wrong_type(self):
        self.assertIsNone(ts.parse_scopes(["registry:my-app:pull"]))

    # -- optional repository allow-list ----------------------------------
    def test_allowlist_accepts_matching_repo(self):
        ts.ALLOWED_REPOS = ["my-app", "rancher/*"]
        self.assertIsNotNone(ts.parse_scopes(["repository:rancher/mirrored-pause:pull"]))

    def test_allowlist_rejects_other_repo(self):
        ts.ALLOWED_REPOS = ["my-app"]
        self.assertIsNone(ts.parse_scopes(["repository:demo-app:pull"]))

    # -- authorisation: authentication -----------------------------------
    def test_authorize_rejects_missing_bearer(self):
        self.assertEqual(ts.authorize("", "GET", "/v2/"), (False, "no bearer token"))

    def test_authorize_rejects_bad_signature(self):
        allowed, reason = ts.authorize("Bearer a.b.c", "GET", "/v2/")
        self.assertFalse(allowed)
        self.assertEqual(reason, "bad signature")

    def test_authorize_rejects_wrong_issuer(self):
        token = self.mint(iss="someone-else")
        self.assertFalse(ts.authorize(f"Bearer {token}", "GET", "/v2/")[0])

    def test_authorize_rejects_wrong_audience(self):
        token = self.mint(aud="another-service")
        self.assertFalse(ts.authorize(f"Bearer {token}", "GET", "/v2/")[0])

    def test_authorize_rejects_expired_token(self):
        token = self.mint(exp=int(time.time()) - 1)
        self.assertFalse(ts.authorize(f"Bearer {token}", "GET", "/v2/")[0])

    def test_authorize_rejects_token_not_yet_valid(self):
        token = self.mint(nbf=int(time.time()) + 300)
        self.assertFalse(ts.authorize(f"Bearer {token}", "GET", "/v2/")[0])

    # -- authorisation: repository scope ---------------------------------
    def test_authorize_allows_unscoped_ping(self):
        token = self.mint()
        self.assertTrue(ts.authorize(f"Bearer {token}", "GET", "/v2/")[0])

    def test_authorize_allows_pull_on_matching_repo(self):
        token = self.mint([{"type": "repository", "name": "my-app", "actions": ["pull"]}])
        self.assertTrue(
            ts.authorize(f"Bearer {token}", "GET", "/v2/my-app/manifests/v1")[0]
        )

    def test_authorize_push_grant_implies_pull(self):
        token = self.mint([{"type": "repository", "name": "my-app", "actions": ["push"]}])
        self.assertTrue(
            ts.authorize(f"Bearer {token}", "GET", "/v2/my-app/manifests/v1")[0]
        )

    def test_authorize_pull_grant_does_not_imply_push(self):
        token = self.mint([{"type": "repository", "name": "my-app", "actions": ["pull"]}])
        self.assertFalse(
            ts.authorize(f"Bearer {token}", "PUT", "/v2/my-app/manifests/v1")[0]
        )

    def test_authorize_rejects_other_repository(self):
        token = self.mint([{"type": "repository", "name": "my-app", "actions": ["pull"]}])
        self.assertFalse(
            ts.authorize(f"Bearer {token}", "GET", "/v2/demo-app/manifests/v1")[0]
        )

    def test_authorize_wildcard_action_covers_push(self):
        token = self.mint([{"type": "repository", "name": "my-app", "actions": ["*"]}])
        self.assertTrue(
            ts.authorize(f"Bearer {token}", "PUT", "/v2/my-app/manifests/v1")[0]
        )


class KeystoneStub(BaseHTTPRequestHandler):
    """Minimal /auth/tokens: only good:secret returns 201."""

    def do_POST(self):
        if self.path != "/auth/tokens":
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        cred = (json.loads(raw or b"{}")
                .get("auth", {}).get("identity", {})
                .get("application_credential", {}))
        if cred.get("id") == "good" and cred.get("secret") == "secret":
            self.send_response(201)
        else:
            self.send_response(401)
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass


class TestHTTP(unittest.TestCase):
    """Token endpoint and auth_request endpoint over real HTTP."""

    @classmethod
    def setUpClass(cls):
        cls.keydir = tempfile.mkdtemp(prefix="token-http-")
        key = pathlib.Path(cls.keydir) / "jwt.key"
        pub = pathlib.Path(cls.keydir) / "jwt.pub"
        subprocess.run(["openssl", "genrsa", "-out", str(key), "2048"],
                       check=True, capture_output=True)
        subprocess.run(["openssl", "rsa", "-in", str(key), "-pubout", "-out", str(pub)],
                       check=True, capture_output=True)
        ts.PRIVATE_KEY = str(key)
        ts.PUBLIC_KEY = str(pub)
        ts.ALLOWED_REPOS = []

        cls.keystone = ThreadingHTTPServer(("127.0.0.1", 0), KeystoneStub)
        threading.Thread(target=cls.keystone.serve_forever, daemon=True).start()
        ts.KEYSTONE_URL = f"http://127.0.0.1:{cls.keystone.server_address[1]}"

        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), ts.TokenHandler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.keystone.shutdown()
        cls.keystone.server_close()
        shutil.rmtree(cls.keydir, ignore_errors=True)

    def request(self, path, method="GET", headers=None, data=None):
        req = urllib.request.Request(self.base + path, method=method,
                                     headers=headers or {}, data=data)
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, dict(resp.headers), resp.read()
        except urllib.error.HTTPError as exc:
            return exc.code, dict(exc.headers), exc.read()

    @staticmethod
    def basic(user, password):
        return "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()

    def mint(self, access):
        now = int(time.time())
        return ts.jwt_sign({
            "iss": ts.ISSUER, "sub": "good", "aud": ts.SERVICE_NAME,
            "iat": now, "nbf": now, "exp": now + 60, "access": access,
        })

    # -- /auth/token ------------------------------------------------------
    def test_token_requires_basic_auth(self):
        code, headers, _ = self.request("/auth/token")
        self.assertEqual(code, 401)
        self.assertIn("Basic", headers.get("WWW-Authenticate", ""))

    def test_token_rejects_bad_base64(self):
        code, _, _ = self.request("/auth/token", headers={"Authorization": "Basic !!!"})
        self.assertEqual(code, 400)

    def test_token_rejects_credentials_without_colon(self):
        header = "Basic " + base64.b64encode(b"nocolon").decode()
        code, _, _ = self.request("/auth/token", headers={"Authorization": header})
        self.assertEqual(code, 400)

    def test_token_rejects_credential_keystone_refuses(self):
        code, _, _ = self.request(
            "/auth/token", headers={"Authorization": self.basic("good", "wrong")})
        self.assertEqual(code, 401)

    def test_token_issues_unscoped_jwt(self):
        code, _, body = self.request(
            "/auth/token", headers={"Authorization": self.basic("good", "secret")})
        self.assertEqual(code, 200)
        payload = json.loads(body)
        claims = ts.jwt_verify(payload["token"])
        self.assertIsNotNone(claims)
        self.assertEqual(claims["iss"], ts.ISSUER)
        self.assertEqual(claims["aud"], ts.SERVICE_NAME)
        self.assertEqual(claims["access"], [])

    def test_token_issues_scoped_jwt(self):
        code, _, body = self.request(
            "/auth/token?service=zot-registry&scope=repository:my-app:pull,push",
            headers={"Authorization": self.basic("good", "secret")})
        self.assertEqual(code, 200)
        claims = ts.jwt_verify(json.loads(body)["token"])
        self.assertEqual(
            claims["access"],
            [{"type": "repository", "name": "my-app", "actions": ["pull", "push"]}],
        )

    def test_token_rejects_malformed_scope_with_400(self):
        code, _, body = self.request(
            "/auth/token?service=zot-registry&scope=repository:my-app",
            headers={"Authorization": self.basic("good", "secret")})
        self.assertEqual(code, 400)
        self.assertIn(b"invalid scope", body)

    def test_token_accepts_post(self):
        # containerd asks for tokens with POST, not GET.
        code, _, _ = self.request(
            "/auth/token", method="POST",
            headers={"Authorization": self.basic("good", "secret")})
        self.assertEqual(code, 200)

    # -- /auth/validate (Nginx auth_request) ------------------------------
    def test_validate_requires_bearer(self):
        code, _, _ = self.request("/auth/validate")
        self.assertEqual(code, 401)

    def test_validate_accepts_scoped_pull(self):
        token = self.mint([{"type": "repository", "name": "my-app", "actions": ["pull"]}])
        headers = bearer(token)
        headers.update({
            "X-Original-Method": "GET",
            "X-Original-URI": "/v2/my-app/manifests/v1",
        })
        code, _, _ = self.request("/auth/validate", headers=headers)
        self.assertEqual(code, 200)

    def test_validate_rejects_push_with_pull_token(self):
        token = self.mint([{"type": "repository", "name": "my-app", "actions": ["pull"]}])
        headers = bearer(token)
        headers.update({
            "X-Original-Method": "PUT",
            "X-Original-URI": "/v2/my-app/manifests/v1",
        })
        code, _, _ = self.request("/auth/validate", headers=headers)
        self.assertEqual(code, 401)

    def test_validate_rejects_expired_token(self):
        now = int(time.time())
        token = ts.jwt_sign({
            "iss": ts.ISSUER, "sub": "good", "aud": ts.SERVICE_NAME,
            "iat": now - 120, "nbf": now - 120, "exp": now - 60, "access": [],
        })
        code, _, _ = self.request("/auth/validate", headers=bearer(token))
        self.assertEqual(code, 401)

    def test_unknown_path_returns_404(self):
        code, _, _ = self.request("/nope")
        self.assertEqual(code, 404)


if __name__ == "__main__":
    unittest.main(verbosity=2)

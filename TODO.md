# TODO — hardening plan

Priority follows the order requested. P1+P2+P4 touch the same scripts, so they are
best verified in **one** full `XX_RUN_FROM_SNAPSHOT.sh` run (03→12, ~20 min).
P5's lint can run immediately and needs no lab. P3 is explicitly least important.

Legend: `[ ]` open · `[~]` written but not yet proven live · `[x]` done and verified

**Status (this pass):** P1, P2, P4 and most of P5 are implemented **and verified
live**. The token logic was unit-tested (22 pure-function + 7 HTTP checks),
`verify.sh` caught the old scope gap on the pre-fix lab (17 passed, 1 failed),
and against the hardened lab it reports **18 passed, 0 failed**. P1.4 is proven:
`11.log`/`12.log` never mention `docker.io`, and a worker pulled an image through
the authenticated registry in 2.2 s. P3 remains deferred.

---

## P1 — Air-gap: make the claim true, or delete it

**Status:** optional by decision — if it does not go green, remove the air-gap
language from `README.md` / `ARCHITECTURE.md` instead of keeping a half-truth.

Today the only runtime internet dependency is in `11` and `12`:

```bash
11:60   push_image docker://docker.io/library/nginx:alpine  docker://$AUTH_PROXY_FIP:5000/my-app:v1
12:134  push_image docker://docker.io/library/busybox:latest docker://$AUTH_PROXY_FIP:5000/demo-app:v1
```

- [x] **P1.1 — Vendor both images next to the other offline binaries.**
  `skopeo` 1.13.3 is on the host; docker.io is reachable now (HTTP 401 = alive).
  ```bash
  ./skopeo copy --override-arch amd64 \
    docker://docker.io/library/nginx:alpine \
    docker-archive:vendor/nginx-alpine.tar:nginx:alpine
  ./skopeo copy --override-arch amd64 \
    docker://docker.io/library/busybox:latest \
    docker-archive:vendor/busybox.tar:busybox:latest
  ```
  - `--override-arch amd64` keeps the tar single-arch (multi-arch index would
    balloon it; the nodes are amd64-only).
  - Record source digests in `vendor/IMAGES.txt` for reproducibility.
  - Add `vendor/` to `.gitignore` and to the README "download required binaries"
    list, exactly like `k3s` / `zot-linux-amd64`.
  - Expected size: ~20 MB + ~4 MB.

- [x] **P1.2 — `11_enable_zot_auth.sh`: push from the vendored tar, not docker.io.**
  - `scp` `vendor/nginx-alpine.tar` to the master (or reuse an existing copy).
  - `skopeo copy docker-archive:/tmp/nginx-alpine.tar:nginx:alpine docker://…/my-app:v1`.
  - Keep the existing 4×15 s retry wrapper (it now covers registry flakiness only).

- [x] **P1.3 — `12_demo_deploy.sh`: same for busybox → `demo-app:v1`.**

- [x] **P1.4 — Prove it.** `10`/`11`/`12` logs must contain zero `docker.io` pushes,
  and the run must stay green. Cheapest hard test: temporarily
  `curl`-block docker.io from the master, or assert in `11` that the source
  transport is `docker-archive:`.

- [x] **P1.5 — Docs.** State "build-time internet only; deploy-time air-gapped",
  list the two vendored tars. **If P1 fails:** delete the air-gap claim entirely.

**Acceptance:** `grep -c docker.io 11.log 12.log` → 0; both apps still 200;
no `skopeo` internet egress during 11/12. **Met:** `11.log` and `12.log` contain
0 occurrences of `docker.io` and 0 of `000000`, and both apps answer 200.

---

## P2 — Security: close the three gaps (+ extras), then test them

### The three gaps
1. Internal CIDRs bypass auth entirely (`satisfy any` + `allow` in `10`).
2. `validate_bearer_token()` checks **only signature + `exp`** — not `aud`,
   `iss`, or the `access` claim.
3. The token service signs **whatever scope the client asks for**, unchecked.

Net: any valid app credential can push to any repo, and a `pull`-only token
works for push.

- [x] **P2.1 — Enforce scope in `validate_bearer_token()` (`10_registry_smoke_test.sh:50`).**
  The nginx plumbing already exists — `X-Original-URI $request_uri` is set at
  `10:212`, so no config change is needed for this part.
  - Parse `/v2/<name>/manifests/<ref>`, `/v2/<name>/blobs/<digest>`,
    `/v2/<name>/tags/list` → repo `<name>`.
  - Required action from method: `GET`/`HEAD` → `pull`;
    `PUT`/`POST`/`PATCH`/`DELETE` → `push`.
  - Verify `iss == "auth-proxy"`, `aud == "zot-registry"`, `exp > now`,
    and `access` contains `{type: repository, name: <repo>, actions: […]}`
    with the required action (`push` implies `pull`).
  - Reject with 401 otherwise. `GET /v2/` (ping) needs a valid token but no scope.
  - Keep it ≤ ~40 lines; add a comment block explaining the v2 spec mapping.

- [x] **P2.2 — Stop trusting client-supplied scope (`10:134`, `08:69`).**
  - Validate `repository:<name>:<actions>`; bad format → **400**, not a 500
    from `scope.split(":")[2]` (today a malformed scope crashes the handler).
  - Whitelist actions `{pull, push}`; dedupe.
  - Optionally allowlist repo names (`my-app`, `demo-app`, `rancher/*`) via a
    config file on the registry VM — makes "any credential → any repo" impossible.
  - Keep binding the credential to the project via Keystone (already done).

- [x] **P2.3 — Remove the IP allow-list bypass (`10:186-191`).**
  - Delete `satisfy any`, `allow $K3S_CLUSTER_CIDR`, `allow $K3S_SERVICES_CIDR`,
    `deny all` — `auth_request` becomes the only gate.
  - `09_k3s_cluster_install.sh` must then make node pulls work **with credentials**:
    add to `registries.yaml`
    ```yaml
    configs:
      "10.20.0.91:5000":
        auth:
          username: <AUTH_PROXY_APP_CRED_ID>
          password: <AUTH_PROXY_APP_CRED_SECRET>
    ```
    Both vars are already persisted by `03` — no ordering problem.
  - Sequence check: `09` pulls before auth is enforced (fine); `10` turns
    enforcement on; `12` pulls with the credential from `registries.yaml`.
  - **Fallback if containerd's token flow misbehaves:** keep the allow-list but
    narrow it to the registry VM's own addresses, and document the residual risk.
  - This change also makes `11`'s push a *real* authenticated push for the first
    time (today the master is whitelisted, so the credentials are decorative).

- [x] **P2.4 — (extra) Test auth from a genuinely external client.**
  `11`/`12` push from the master (`10.10.0.6`), which was inside the allow-list —
  so "authenticated push" was never exercised. Add a host-side (external) test:
  - `401` with no token,
  - `201` push with the app credential,
  - `401/403` with a pull-only token on `PUT`.
  - Add these as hard assertions at the end of `10`.

- [ ] **P2.5 — (extra, optional) TLS.** Add self-signed certs for nginx:5000 and
  drop `--dest-tls-verify=false`; or explicitly document that credentials are
  cleartext on a host-only network. Given nested virt + a lab, documenting is
  acceptable — but say it out loud in the README.

- [ ] **P2.6 — (extra, optional)** JWT key `chmod 600`, `/auth/token` rate limit,
  token revocation list. Nice-to-have, not blocking.

**Acceptance:** external `GET /v2/` → 401; token → 200; pull-scope token on `PUT`
→ 401/403; no `allow`/`satisfy` left in the rendered nginx config; `09` reaches
2/2; `12` both apps 200.

---

## P3 — Reproducibility (least important)

- [ ] **P3.1** Stop re-uploading the 629 MB cloud image on every run: pre-seed
  `/home/ubuntu/ubuntu-noble.img` **into the snapshot** (one-time manual
  `snapshot-create-as`), and have `03` register it with `--file` from the VM's
  own disk before attempting `scp`.
- [ ] **P3.2** `03`: try VM-local path → then repo copy → only then fail.
- [ ] **P3.3** Idempotency sweep: run each of `03`→`12` twice without a revert and
  fix the 400s/duplicates found (expect: volume attach, SG rules, FIP allocate).
- [ ] **P3.4** Per-step elapsed time in the `XX_` summary, so slow steps are visible.

---

## P4 — Verification (do this early; it pays for itself)

- [x] **P4.1 — `ci/lint.sh`**: `bash -n` + `shellcheck -x` over every `*.sh`
  (exclude `vendor/`). Add `.shellcheckrc` with `disable=SC1090,SC1091`
  (dynamic sourcing of `lib/common.sh`) and `shell=bash`.
- [x] **P4.2 — pre-commit hook** `hooks/pre-commit` → `ci/lint.sh`;
  `make lint` target; document `git config core.hooksPath hooks`.
- [x] **P4.3 — `verify.sh`** (read-only, external to the scripts' own claims):
  host curl both URLs, nodes `Ready` 2/2, pod placement, cross-node pod→pod curl,
  worker SG `protocol=any` + `10.10.0.0/24`, `/v2/_catalog` has **all 8**
  `rancher/…` repos, pod image IDs point at `10.20.0.91:5000`, no `000000`.
- [x] **P4.4** Harden `10`: catalog must contain all 8 mirrored images (today it
  asserts only `rancher/mirrored-pause`), plus the P2.4 negative tests.
- [ ] **P4.5** (optional) `kubeconform` on the rendered manifests.

---

## P5 — Hygiene + `99_teardown.sh` (do not test teardown)

- [x] **P5.1 — One token service, one source of truth.** Extract to
  `lib/token_service.py`; `08` installs it, `10` stops rewriting the file with a
  second copy (today `08:41` and `10:82` both define `TokenHandler`). `10` may
  still *verify* it.
- [x] **P5.2** `local.conf`: it is the DevStack sample default (`nomoresecret`),
  not a real leak — add a one-line comment saying so. Optionally add
  `local.conf.example` (do not change `02`'s behaviour: 01/02 are frozen).
- [x] **P5.3** README table says `07` is a no-op; it actually aliases
  `AUTH_PROXY_FIP`/`AUTH_PROXY_INTERNAL_IP`. Fix the description, keep the step.
- [x] **P5.4 — `99_teardown.sh` (write, DO NOT RUN):** idempotent, requires `--yes`,
  `--revert` optional. Order: delete NodePort services + demo/prod workloads →
  uninstall k3s agent/server → delete worker/master/registry servers →
  delete volumes → release FIPs → delete SGs → delete router/ports/networks →
  keypair → app credential → image → optionally `XX_revert_to_snapshot.sh`.
  Every step `|| true` with a logged skip, and a final summary of what remained.
  - [x] Written as `99_teardown.sh`: dry-run by default, `--yes` to act,
    `--revert` to also restore the snapshot. **Deliberately not executed.**
- [x] **P5.5 — `Makefile`**: `lint`, `run`, `verify`, `teardown`; README pointer.
- [x] **P5.6** Review `notes.txt` / `precautions.txt`: keep if they hold real
  debugging value, otherwise drop. Add `vendor/` to `.gitignore`.
- [x] **P5.7 — Docs sync**: auth boundary (no IP bypass), air-gap truth,
  teardown, and the fact that `11` now authenticates for real.

---

## Definition of done

1. `XX_RUN_FROM_SNAPSHOT.sh` exits 0 from `PostStack_Ready`.
2. `09` nodes 2/2 · `10` all guards PASS · `12` both apps 200.
3. No `docker.io` push in `11`/`12`; no `allow`/`satisfy` in nginx.
4. `scope` negative test fails closed (401/403), forged `aud` rejected.
5. `ci/lint.sh` clean; `verify.sh` all PASS.
6. Docs match reality; `99_teardown.sh` exists and is untested by design.

## Risk register

| Risk | Mitigation |
|---|---|
| containerd can't do the token flow with `registries.yaml` auth | fallback: narrow allow-list to the registry VM and document |
| Removing the bypass breaks `12`'s image pull | test in one run; keep the old config in git to revert fast |
| Vendored tars push the repo/offline bundle past ~1.2 GB | ~24 MB only; `--override-arch amd64` |
| `--protocol any` regression while touching `10` | leave `ensure_rule` untouched; `09` already gates on 2/2 |
| Teardown deletes something the user still wants | `--yes` guard + dry-run listing by default |

---

## Run log

| Run | Command | Result |
|---|---|---|
| token logic (unit) | `/tmp/opencode/token-test` — 22 pure-function checks + 7 HTTP checks | 22/22, 7/7 PASS (deny lines: bad scope, cross-repo) |
| pre-fix lab | `./verify.sh` against the old deployment | 17 passed, 1 failed — caught `pull-only token allowed on push (400)` |
| P1+P2+P4 live, first pass | `sudo bash XX_RUN_FROM_SNAPSHOT.sh` from `PostStack_Ready` | 03→09 OK; `10` aborted silently (Ubuntu `.bash_logout` bug, fixed) |
| `10` after the fix | `./10_registry_smoke_test.sh` | T1–T7 + catalog all PASS, EXIT=0 |
| `11` first attempt | `./11_enable_zot_auth.sh` | push OK, pod `ImagePullBackOff`: certs.d host had an https-only `server` line (fixed in `09`) |
| `11`/`12` after the registry fix | `./11_enable_zot_auth.sh && ./12_demo_deploy.sh` | both EXIT=0, 0 `docker.io`, 0 `000000`; worker pulled `my-app` fresh in 2.2 s through the token flow |
| `verify.sh` | `./verify.sh` against the finished lab | **18 passed, 0 failed** |
| lint | `./ci/lint.sh` over 22 tracked scripts | OK |

Rollback point for the pre-hardening state: `PRE_HARDENING_COMMIT.txt` (gitignored)
records commit `5aaa916`.

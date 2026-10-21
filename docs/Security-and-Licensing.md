# Security & Licensing model

How the Agent Gateway binaries are packaged, protected and licensed — and
what you are responsible for. This page also documents the **OWASP ZAP
security scan** of the demo stack's core containers (see
[ZAP security scanning](#zap-security-scanning-of-the-core-containers)).

## The packaging model

Every service image (`stevef1uk/agent-gateway-{authz,gateway,tokensvc,web}`)
is built with a three-stage Docker build:

1. **Build stage** — the Go code is compiled into a static binary.
2. **Packaging stage** — the binary is placed in a payload directory and
   sealed with the [secure-packager](https://hub.docker.com/r/stevef1uk/secure-packager)
   tool:
   - **envelope encryption** — the payload is encrypted to the *customer
     public key* (baked into the image at build time); only the matching
     private key can decrypt it;
   - **vendor licence manifest** — the package carries `license_required` and
     the *vendor public key*; the decrypted runtime refuses to start without
     a valid, vendor-signed licence token;
   - the result is a single encrypted `.zip` inside the runtime image, plus
     the small `unpack` helper.
3. **Runtime stage** — a tiny Alpine image with **only** the encrypted
   payload, the unpack tool and an entrypoint: no plaintext binary ever
   exists in the image or in the registry.

## What happens at start-up

```
1. read the licence token from /licences/<service>.token
2. check expiry/signature against the baked-in vendor public key
   → expired or missing token: clear error, container exits
3. unpack the encrypted payload with the customer private key at
   /keys/customer_private.pem
   → wrong key: unpack fails with a decryption error
4. exec the decrypted binary
```

Four consequences:

- **Images alone are inert.** Copying them from Docker Hub gives nothing
  without your private key *and* a valid licence token.
- **Expiry is enforced by execution**, not by bookkeeping: an expired licence
  is a loud start-up failure (see [Demos.md](Demos.md) troubleshooting), so a
  subscription lapse cannot silently degrade security.
- **The vendor signature is the enforcement anchor** (right-to-run, expiry,
  who it was issued to); the customer key pair is the confidentiality anchor
  (only the paying customer can run the software).
- **Keys cannot be rotated in-place** without a new image build — public keys
  are baked in at build time. Contact the vendor for a key-rotation build.

## Artifact responsibilities (yours vs ours)

| Artifact | Held by | Notes |
|---|---|---|
| `customer_private.pem` | **you** | never in images, never in git; mount read-only `/keys/customer_private.pem`. Loss = vendor rebuild with a new key pair. |
| `customer_public.pem` | baked into images | identifies your decryptability, not a secret |
| `vendor_public.pem` | baked into images | verifies licence tokens |
| `vendor_private.pem` | **vendor only** | signs licence tokens. **Never** distributed |
| `license.token` | you (file) | vendor-signed, expiry carried inside; replace at renewal and restart |

## Licence tokens

A token is a base64 field pair: `expiry:company:email` plus an HMAC signature
from the vendor key over the whole record. The runtime parses the expiry and
rejects tokens dated in the past, passing the token to `unpack` which
verifies the signature against the vendor public key. Token issuance is a
vendor-side operation (`issue-token`), delivery is an email attachment; the
renewal runbook is a file swap + `docker compose restart` — the publisher
runbook in [Deployment-Guide.md](Deployment-Guide.md).

## Evaluation & demo keys

The [public demo repository](../README.md) ships `demo/keys/` containing a
development key pair and a token — that is what makes the public images run
without contacting the vendor. Understand what this means:

- the demo private key is **public** — it proves the packaging mechanics work,
  and it does not compromise any *other* customer, because each paying
  customer's images are built with *their own* public key;
- the demo licence token carries an expiry date — extendability and renewals
  are exactly what a paid licence changes;
- anything you run with demo keys is still a **development environment**: use
  the normal [Deployment-Guide.md](Deployment-Guide.md) hardening for real
  workloads; request your own customer key pair and token by email.

## Licence liability, in one section

The commercial licence is a standard AS-IS grant: no warranty of
merchantability or fitness for your purpose, you must evaluate in
non-production before production use, licensee indemnity on agent actions,
and the vendor's aggregate liability capped at fees paid in the prior
12 months (nil on free tiers). Full text:
[Commercial-Licence.md](Commercial-Licence.md).

## Hardening checklist for the container runtime

From [Deployment-Guide.md](Deployment-Guide.md), the minimum:

- mount `keys/` and `licences/` read-only (`:ro`)
- keep `JWT_SECRET` (32+ random bytes) identical across authz/tokensvc/gateway
- run behind your own TLS termination; choose SPIFFE mTLS mode for agents
  where feasible
- ship logs to your SIEM — every allow/deny lives in `audit_events`
- restart cadence: tokens reload at container start; a token replacement does
  not require an image pull — only a restart

## ZAP security scanning of the core containers

The demo stack's five core containers are scanned with
[OWASP ZAP](https://www.zaproxy.org) (the industry-standard open-source web
scanner) using the vendor's
[baseline scan](https://www.zaproxy.org/docs/docker/baseline-scan/):
each service is spidered and passively scanned for missing security headers,
insecure cookies, vulnerable JS libraries, TLS/configuration issues and more.

Run it with:

```bash
./security/zap-scan.sh             # or: make security-scan
```

The script ( [`security/zap-scan.sh`](../security/zap-scan.sh) ):

1. **brings the demo stack up** — `docker compose -f docker-compose.yml
   -f docker-compose.egress.yml up -d` in `demo/`, so the scan covers the same
   stack (including the gateway's egress proxy overlay) the demos use;
2. **waits for each service's `/healthz`** to pass;
3. **runs one ZAP container per core service** (`zaproxy/zap-stable`,
   host network, so it reaches the same published ports your agents use) —
   the gateway PEP, authz, tokensvc, web and demoapi (third-party supporting
   services — Dex, redis, postgres — are excluded by default);
4. **writes the HTML + JSON report for every service into
   `security/results/`**, one file per service, overwritten on each run so
   the folder always holds the latest reports, plus a `summary.txt` with the
   per-service verdict.

### Latest reports

Generated by [`security/zap-scan.sh`](../security/zap-scan.sh). The reports
are committed as **Markdown** — the one format the git interface renders
in the browser (plain `.html` would be served as source there). Each scan
overwrites the files; a fresh check needs a fresh look at `git diff`:

| Service (container) | Report (markdown, rendered in the git UI) |
|---|---|
| gateway — the policy enforcement point (PEP) | [`security/results/gateway.md`](../security/results/gateway.md) |
| authz — decision point | [`security/results/authz.md`](../security/results/authz.md) |
| tokensvc — short-lived token mint | [`security/results/tokensvc.md`](../security/results/tokensvc.md) |
| web — admin console | [`security/results/web.md`](../security/results/web.md) |
| demoapi — protected API stand-in | [`security/results/demoapi.md`](../security/results/demoapi.md) |

Full-machine-readable variants when a tool needs them (CI, SIEM): run the
scan with `JSON=1 ./security/zap-scan.sh` for `*.json`, or `HTML=1` for the
original ZAP-styled `*.html` files (both land beside the `.md`, not
committed).

### Scan history and what was fixed

| Run | Scanned build | gateway | authz | tokensvc | web | demoapi | summary |
|---|---|---|---|---|---|---|---|
| 2026-10-21 (a) — before browser hardening | web 1.0.42, demoapi 1.0.5 | `0 alerts` | `0 alerts` | `0 alerts` | 2 Medium CSP advisories + 3 Low | 3 Low | |
| 2026-10-21 (b) — after browser hardening | web 1.0.44, demoapi 1.0.6 (the compose pins) | `0 alerts` | `0 alerts` | `0 alerts` | `0 alerts` | `0 alerts` | [`security/results/summary.txt`](../security/results/summary.txt) |

(A scanner quirk worth knowing: ZAP's baseline **exit code** stays `0` even
when Warn-level advisories exist — run (a)'s findings live in the HTML report
only, which is exactly why you read the reports and not just the exit code.)

**Run one yourself.** The committed reports under
[`security/results/`](../security/results/) are the latest released-build
snapshots (refreshed when a release commit bumps the stack); the scanner is
not a black box and you shouldn't trust a snapshot over your own eyes:

```bash
./security/zap-scan.sh            # or: make security-scan
```

That re-runs everything against the running stack (compose up included),
overwrites the same report files with fresh results and prints the
per-service verdicts; review `security/results/*.md` locally. Going
deeper: `FULL=1 ./security/zap-scan.sh` (active `zap-full-scan.py`), and the
env overrides habitually used by release validation
(`WEB_IMAGE`/`DEMOAPI_IMAGE` → the compose pins those images) are listed in
the script header. On Kubernetes/k3s the same five images are scanned by
pointing the scan's `TARGETS` at the NodePort-hosted URLs.

**What "browser hardening" changed.** Run (a)'s findings on the web console
(ZAP plugin 10055 — `script-src` and `style-src` include `'unsafe-inline'`) had
two parts, both resolved in our own code:

- **The console's own markup.** The console pages shipped one inline
  `<style>` + one inline `<script>` per page (single-file HTML) plus `style=`
  attributes and inline `on*=` event handlers — that is what `'unsafe-inline'`
  was keeping alive. All three pages (`index.html`, `demo.html`,
  `policy.html`) now serve their script and CSS as static assets from
  `web/assets/*` (same markup, same boot order, behaviour-preserving), the
  inline event handlers became `data-action` attributes handled by a single
  delegated listener, and the response CSP tightened to `script-src 'self';
  style-src 'self'` — no inline permits. Shipped as **web 1.0.43** (product
  repo Makefile: `VERSION_WEB=1.0.43`).
- **Third-party IdP pages are deliberately exempt.** During the browser
  sign-in flow the web tier relays the identity provider's own rendered
  content under `/oidc/idp/*`. That is third-party vendor content
  (Dex in the demo — which today ships no inline script/style — and
  Keycloak/Okta/Entra in enterprise deployments): we do not own it, do not
  stamp hardening onto it, and it is exactly the surface companies replace
  with their own IdP. A strict policy fixed for one provider would be
  guesswork against the rest. Enterprise deployments that need it set
  `WEB_INSECURE_IDP_CSP=1` to give ONLY the relayed pages the inline-permit
  policy (the console keeps the strict policy regardless).
- **Cross-origin isolation headers.** ZAP's extra findings (missing
  `Cross-Origin-Opener/Embedder-Policy` on web; missing `nosniff`/CORP on
  demoapi) were resolved by setting defensive response headers in both
  projects' code (the gateway stack's shared `httpx.SecureHeaders`, and a
  mirror middleware in `demo/api`). demoapi rebuilt as **1.0.6**.
- Nothing third-party was patched: Dex, redis, postgres and the OPA image
  are untouched, and no vendor IdP content is constrained.

**Validation, and where the builds stand.** web **1.0.44** and demoapi
**1.0.6** are published to Docker Hub (multi-arch, both tag and `:latest`)
and validated end to end — the Playwright UI suite in the product repo
(`test/e2e/ui_pages_test.js`: 18/18 on the published 1.0.42 baseline first,
then 24/24 with the OPA engine on the new build — SSO round trip, delegation
create/revoke, approval decisions, the full nine-step guided demo, policy
probes ALLOW/approval-required/DENY, policy edit + hot-reload + break
refusal + restore, sign out — with zero CSP violations) plus `go vet`/
`go test` (both projects) and a final baseline scan on the released pins
(table above, run (b)). The demo compose, k3s manifests and Deployment
Guide now pin `1.0.44`/`1.0.6`.

### Reading the results and tuning the run

- **Baseline vs full.** The default baseline scan is quick and
  passive-leaning; it does not authenticate, attempt forms or actively
  exploit. For a deeper (slower, actively probing) pass against a service run
  `FULL=1 ./security/zap-scan.sh` (`zap-full-scan.py`). Neither mode is a
  substitute for a human penetration test of a production deployment.
- **Exit code.** `0` when every scan ran and nothing was unreachable.
  Findings alone do not fail the run — read the reports — but
  `FAIL_ON_ALERTS=1` makes any alert a failure (useful in CI).
- **Overrides (env):** `ZAP_IMAGE` (default `zaproxy/zap-stable`),
  `COMPOSE` (default `docker compose`, else `docker-compose`),
  `TARGETS="name=hostport ..."` (default: the five services above),
  `GATEWAY_HOST_PORT` (default: the `demo/.env` value, else 8080 — the same
  override compose and the benchmark use),
  `WAIT` (healthz wait, default 120s).
- **Where ZAP runs from.** The ZAP container uses the host network, so it
  needs a Linux Docker host (portable Docker Desktop setups would need the
  `host.docker.internal` variant instead). The stack keeps running after the
  scan, exactly as the demos leave it.

# Agent Gateway — End-User Deployment Guide

*For teams who consume the pre-built Docker images and run Agent Gateway on
their own infrastructure — from a single laptop node to a highly available
enterprise deployment.*

---

## 1. What Agent Gateway is

Agent Gateway puts **human-controlled authorisation in front of the tools and
APIs your AI agents can call**. Agents are no longer trusted implicitly: every
tool call is checked against a *delegation* — a short-lived, scoped grant a
human created after signing in with enterprise SSO — and anything above a
pre-agreed risk threshold stops and waits for a named human to approve it.
Every decision, allow or deny, lands in an immutable audit trail.

```
              OIDC (Okta / Entra / Keycloak / Dex)
 Human ──────────────► ┌─────────────────────────────┐
                       │  authz   (decision point)   │  delegations, policy,
                       │           :8081             │  user identity (OIDC)
                       ╰──────────┬──────────────────╯
                                  │ mint scoped token
                       ┌──────────▼──────────────────┐
 AI Agent ──token──►   │  gateway (enforcement point)│  every call: resolve
                       │           :8080             │  principal → policy →
                       ╰──────────┬──────────────────╯  approve? → audit
                                  │ forward only if allowed
                       ┌──────────▼──────────────────┐
                       │  your tools / internal APIs │
                       ╰─────────────────────────────┘

 Supporting services:
   tokensvc :8082   mints short-lived, delegation-scoped JWTs
   web      :8083   admin UI: delegations, approvals, audit
   postgres :5432   durable store (delegations, approvals, audit) — optional
   redis    :6379   instant token revocation + decision cache   — optional
```

The gateway, tokensvc and authz run as stateless containers (the web console keeps its sign-in sessions in memory, so run a single web replica), so scaling is a matter of
running more replicas in front of your load balancer.

---

## 2. What you receive

| Artifact | Purpose |
|---|---|
| `stevef1uk/agent-gateway-authz` | Authorisation/decision service (:8081) |
| `stevef1uk/agent-gateway-gateway` | Policy enforcement point (:8080) |
| `stevef1uk/agent-gateway-tokensvc` | Token minting service (:8082) |
| `stevef1uk/agent-gateway-web` | Admin web UI (:8083) |
| `customer_private.pem` | Your private decryption key — **kept secret, mounted at runtime** |
| Licence token file (e.g. `license.token`) | Time-limited right-to-run, signed by the vendor |

Throughout this document replace the image prefix with the registry path on
your licence, e.g. `docker.io/stevef1uk/agent-gateway-authz:1.0.12`.

The images are published on Docker Hub under `stevef1uk` and can be pulled
as:

```bash
docker pull stevef1uk/agent-gateway-authz:1.0.12
docker pull stevef1uk/agent-gateway-gateway:1.0.24
docker pull stevef1uk/agent-gateway-tokensvc:1.0.5
docker pull stevef1uk/agent-gateway-web:1.0.44
```

Each tag is a **multi-arch** manifest (`linux/amd64` + `linux/arm64`), so the
same tag runs natively on x86-64 servers and Apple-silicon Macs.

Choose specific version tags for production (`1.0.22`) over `latest` so
rollback and licence enrolment are deterministic; record the pulled digests:

```bash
docker images --digests --filter=reference='stevef1uk/agent-gateway-*'
```

### How the image protection works (10 seconds)

Each image contains an **encrypted** copy of its program. At start-up the
container:

1. loads your licence token, checks it against the vendor's public key baked
   into the image, and verifies it has not expired;
2. decrypts the program using your private key;
3. runs the service.

This means **no customer private key at runtime = nothing runs** — even if the
image itself is copied, it is inert without both of your keys.
The corresponding *public* key is baked into the images at build time, so
key pairs must match: private key ≠ mismatched key pair will fail exactly at
"Customer private key not found"-style steps below.

---

## 3. Requirements

- Docker Engine 24+ (or any container runtime that supports bind mounts and
  secrets). Kubernetes in §6 is optional.
- Outbound registry access to pull the images.
- Postgres 14+ **and** Redis 7+ if you use `PERSISTENCE=postgres`
  (strongly recommended in production; the built tables are auto-created).
- An OIDC provider for SSO (Okta, Microsoft Entra ID, Keycloak, Dex — §7.2).
- Mounted keys: `customer_private.pem` and the licence token supplied by the
  vendor.

---

## 4. Quickstart — single node, five minutes

### 4.1 Layout

```
/opt/agent-gateway/
├── keys/
│   ├── customer_private.pem    # 600, nobody else should read this
│   └── license.token           # the vendor licence
└── docker-compose.yml
```

### 4.2 Minimal `docker-compose.yml` (memory persistence, SSO off)

This is the fastest way to get a working stack; production settings follow
later.

```yaml
services:
  authz:
    image: stevef1uk/agent-gateway-authz:1.0.12
    restart: unless-stopped
    ports: ["8081:8081"]
    environment:
      - PERSISTENCE=memory
      - JWT_SECRET=<32+ random bytes>        # same on every service!
      - TOKEN_TTL=5m
    volumes:
      - ./keys:/keys:ro
      - ./keys/license.token:/licences/authz.token:ro

  tokensvc:
    image: stevef1uk/agent-gateway-tokensvc:1.0.5
    restart: unless-stopped
    ports: ["8082:8082"]
    environment:
      - JWT_SECRET=<same as authz>
      - AUTHZ_URL=http://authz:8081
    volumes:
      - ./keys:/keys:ro
      - ./keys/license.token:/licences/tokensvc.token:ro

  gateway:
    image: stevef1uk/agent-gateway-gateway:1.0.24
    restart: unless-stopped
    ports: ["8080:8080"]
    environment:
      - AUTHZ_URL=http://authz:8081
      - JWT_SECRET=<same as authz>
      # - DECISION_CACHE_TTL=5s    # optional: throughput ↔ revocation latency trade-off, see §5
    volumes:
      - ./keys:/keys:ro
      - ./keys/license.token:/licences/gateway.token:ro

  web:
    image: stevef1uk/agent-gateway-web:1.0.44
    restart: unless-stopped
    ports: ["8083:8083"]
    environment:
      - AUTHZ_URL=http://authz:8081
      - GATEWAY_URL=http://gateway:8080
    volumes:
      - ./keys:/keys:ro
      - ./keys/license.token:/licences/web.token:ro
```

> **Note** — `JWT_SECRET` must be identical on `authz`, `tokensvc` and
> `gateway`: each service signs/validates the same short-lived agent tokens.
> Generate once: `openssl rand -hex 32`.

Start and verify:

```bash
docker compose up -d
for p in 8081 8082 8080 8083; do curl -s http://localhost:$p/healthz; echo; done
```

You should see `{"status":"ok"}` four times. Login to the admin UI on
`http://localhost:8083`.

### 4.4 Demos you can run immediately

* **Scripted demo** — `demo/demo.sh` (this repository): walks the whole
  authorization story live — SSO sign-in, delegation, token minting,
  auto-allow, approval hold, human approval, instant revocation — with
  explanations at each step.
* **Claude.ai connector** — the remote-MCP flow (compose + quick tunnel, or
  the k3s ingress track) lives in
  [Claude-Integration.md](Claude-Integration.md); note the three
  delegation-shape requirements there (`initialize`/`list` discovery
  actions, hours-long TTL, subject binding) before relying on the console
  form.
* **Graphical demo** — served by the `web` container from
  `http://localhost:8083/demo.html` (`agent-gateway-web` **1.0.3+**): the same
  nine steps as an interactive, animated walkthrough with a live audit feed,
  spend-cap meter and health pills for every service. Sign-in is one click
  (development SSO connector); all calls are real.
* **OPA policy playground** — `http://localhost:8083/policy.html`
  (`agent-gateway-web` **1.0.11+**): view and edit the live Rego policy the
  authorization service enforces, apply it and watch the hot reload change real
  decisions, then break it on purpose to see the reload refused and the previous
  policy keep serving. **Restore initial policy** puts the committed policy back,
  and **Reload from file** re-reads it after a host-side `git restore`; the page
  also refreshes itself when the file changes on disk. Needs the policy override:
  `docker compose -f demo/docker-compose.yml -f demo/docker-compose.opa.yml up -d`.
  See [Policy-and-OPA.md](Policy-and-OPA.md).

### 4.5 First end-to-end touch (curl)

With SSO disabled (dev mode) the client-asserted user identity is used, so you
can script the whole authorization loop without a browser:

```bash
# 1. A human creates a delegation: agent may create orders (auto-approve ≤ €200)
DELEGATION=$(curl -s -X POST http://localhost:8081/v1/delegations/ \
  -H "Content-Type: application/json" \
  -d '{
    "user_id": "alice", "agent_id": "procurement-bot",
    "resources": ["/orders"], "actions": ["read","create"],
    "expires_in_seconds": 1800,
    "limits": {"spend_per_order": {"type":"currency","max":200,"unit":"EUR"}}
  }')
DELEGATION_ID=$(echo "$DELEGATION" | jq -r .delegation.id)
AGENT_SECRET=$(echo "$DELEGATION" | jq -r .agent_secret)   # one-time mint credential

# 2. The agent exchanges its delegation (id + secret) for a short-lived token
TOKEN=$(curl -s -X POST http://localhost:8082/token \
  -H "Content-Type: application/json" \
  -d "{\"delegation_id\":\"$DELEGATION_ID\",\"ttl_seconds\":300,\"agent_secret\":\"$AGENT_SECRET\"}" | jq -r .access_token)
# Possessing the delegation id alone is not identity: minting requires the
# per-delegation agent secret returned at creation time (see docs/Agent-Identity.md).

# 3. Cheap order: allowed automatically
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8080/orders \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"amount": 150, "supplier": "acme"}'
# → 200

# 4. Expensive order: held for approval (202 + approval_id)
APPROVAL=$(curl -s -X POST http://localhost:8080/orders \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"amount": 250, "supplier": "acme"}' | jq -r .approval_id)

# 5. A human approves (bound to this exact action hash); the gateway's
#    operator endpoints require the admin token (GATEWAY_ADMIN_TOKEN — the
#    demo compose sets it to agent-gateway-demo-admin)
curl -s -X POST http://localhost:8080/v1/approvals/ -H "Content-Type: application/json" \
  -H "X-Admin-Token: ${ADMIN_TOKEN:-agent-gateway-demo-admin}" \
  -d "{\"approval_id\":\"$APPROVAL\",\"approver_id\":\"alice\",\"approved\":true}"

# 6. Retry now succeeds (200); revoke kills the agent even with a valid token
curl -s -X DELETE http://localhost:8081/v1/delegations/$DELEGATION_ID
```

Point `UPSTREAM_URL` at your own backend so the gateway actually forwards
allowed traffic (it returns a synthetic response when unset).

---

## 5. Configuration reference

All configuration is via environment variables (12-factor style).

### Shared (all services)

| Variable | Default | Purpose |
|---|---|---|
| `JWT_SECRET` | `dev-secret-change-in-prod` | HMAC key for short-lived agent tokens. **Must match across authz/tokensvc/gateway. Set explicitly in production.** |
| `JWT_ISSUER` | `agent-gateway` | `iss` claim on issued agent tokens |
| `AUDIENCE` | `agent-gateway` | `aud` claim on issued agent tokens |
| `TOKEN_TTL` | `5m` | Default lifetime of agent tokens (Go duration) |
| `PERSISTENCE` | `memory` | `memory` or `postgres` |
| `DATABASE_URL` | *(empty)* | Postgres DSN, required when `PERSISTENCE=postgres`. Schema is created automatically on startup. |
| `REDIS_URL` | *(empty)* | Enables instant token revocation and the decision cache. Leave set even with `PERSISTENCE=memory`. |
| `DECISION_CACHE_TTL` | off | Optional cache of policy decisions for hot agent traffic. **Security trade-off:** a cached ALLOW keeps serving for up to the TTL even after a delegation is revoked — revocation latency ≤ TTL. Leave off unless your threat model accepts it (revocation within the TTL window is not the design promise). |
| `OIDC_ISSUER_URL` | *(empty)* | **Opt-in SSO.** When set, authz verifies the human's ID token at delegation creation and binds the delegation to the token subject. Unset = dev-only client-asserted identities. |
| `OIDC_CLIENT_ID` | `agent-gateway` | `aud` the ID token must carry |
| `ENABLE_SPIFFE` | `false` | Switch gateway to SPIFFE workload identity (mTLS + SVIDs) — see §7.3 |
| `SPIFFE_WORKLOAD_API` | `unix:///run/spire/sockets/agent.sock` | Workload API socket for SPIRE agent (sidecar) |

### Per service

| Service | Extra variables |
|---|---|
| `authz` | `AUTHZ_ADDR` (`:8081`) |
| `tokensvc` | `TOKENSVC_ADDR` (`:8082`), `AUTHZ_URL` (must point at authz, use the service name inside the compose/k8s network — **not** `localhost`), `TOKENSVC_ALLOW_NO_SECRET_MINT` (default off; legacy mint without an agent secret, dev only) |
| `gateway` | `GATEWAY_ADDR` (`:8080`), `AUTHZ_URL`, `UPSTREAM_URL` (your protected backend; unset = synthetic response for demos), `GATEWAY_ADMIN_TOKEN` (guards `GET/POST /v1/approvals` + `POST /v1/tokens/revoke` via `X-Admin-Token`; unset = those endpoints disabled), `APPROVAL_WEBHOOK_URL` / `APPROVAL_WEBHOOK_SECRET` (push an `approval.required` event whenever an action is held — HMAC-signed; see [Notifications.md](Notifications.md)) |
| `web` | `WEB_ADDR` (`:8083`), `AUTHZ_URL`, `GATEWAY_URL`, `WEB_DIR` (static assets, do not change), `GATEWAY_ADMIN_TOKEN` (forwarded to the gateway's operator endpoints), `WEB_SESSION_TTL` (default `8h`), `DEMO_UI` (default off — serves `demo.html`, `policy.html` and their APIs), `POLICY_FILE` + `POLICY_DEFAULT_FILE` (OPA playground, needs the OPA override), `PUBLIC_GATEWAY_URL` (where agents reach the gateway from the browser's network — set on NodePort/Ingress deployments; see `k3s/`) |

### Container runtime keys (all four images)

| Variable | Default | Purpose |
|---|---|---|
| `PRIVATE_KEY_PATH` | `/keys/customer_private.pem` | Your decryption key, mount read-only |
| `LICENCE_TOKEN_PATH` | `/licences/<service>.token` | Vendor licence file, mount read-only |
| `UNPACK_WORK_DIR` | `/tmp/unpack` | Scratch dir used during decryption (needs to be writable) |

| File mount | Into |
|---|---|
| `./keys:/keys:ro` | all services (private key) |
| `./keys/license.token:/licences/authz.token:ro` (per service) | all services (licence, named per service) |

Optional egress listener (images ≥ gateway 1.0.22): setting
`GATEWAY_PROXY_ADDR=:8088` on the gateway service starts a **forward proxy
listener** through which an agent's entire outbound traffic is enforced
(destination host = resource, method/CONNECT = action, same authz → approval
→ audit pipeline). Unset = not listening, identical to earlier versions.
Bring-up with NVIDIA OpenShell sandboxes / OpenClaw (including a
per-outbound-request human-approval delegation) is documented in the main
repo's [`OpenShell-Integration.md`](
https://github.com/stevef/agent-gateway/blob/main/OpenShell-Integration.md).

### Security hardening (applied after an OWASP ZAP review)

The images ship non-root: service processes run as unprivileged user `app`
(UID 1000); run them with `no-new-privileges` (the demo compose does). The
console additionally enforces:

- **Gateway operator endpoints are token-gated.** `GET/POST /v1/approvals` and
  `POST /v1/tokens/revoke` require `X-Admin-Token` to match
  `GATEWAY_ADMIN_TOKEN`; without that variable the endpoints stay disabled
  (HTTP 503). Set the same variable on the `web` service — the console
  forwards it server-side for its approve/deny buttons.
- **The console requires sign-in.** After the OIDC sign-in the browser holds
  only an opaque `HttpOnly` session cookie (`web_session`); the verified ID
  token lives server-side, and delegation creation attaches it there — no
  readable credential cookie for XSS to lift. All actionable console APIs
  (`/api/delegations*`, `/api/approvals*`, `/api/tokens`, `/api/gateway/call`)
  return 401 without a session.
- **R&D demo surfaces are opt-in.** `demo.html`, `policy.html` and their APIs
  exist only when `DEMO_UI=1` (the demo compose sets it). Production omits
  the flag — the pages 404. Operators can also toggle at runtime from the
  console ("R&D demo pages" button, `POST /api/demo-mode`); a restart returns
  to the `DEMO_UI` default.
- **Security headers everywhere**: `X-Content-Type-Options: nosniff`,
  `Referrer-Policy: no-referrer`, `Permissions-Policy`,
  `Cross-Origin-Resource-Policy` on every service; the console adds
  `Content-Security-Policy` (script/style `self`, `object-src 'none'`,
  `base-uri 'self'`, `frame-ancestors 'none'`) and `X-Frame-Options: DENY`.
- **Approval notifications**: with `APPROVAL_WEBHOOK_URL` (HMAC-signed via
  `APPROVAL_WEBHOOK_SECRET`) set on the gateway, every held action pushes an
  `approval.required` event to your automation (Slack/Teams/n8n/PagerDuty via
  a translator); or send the card to a Telegram chat
  (`APPROVAL_TELEGRAM_BOT_TOKEN` + `APPROVAL_TELEGRAM_CHAT_ID`). The console also notifies in-page: a red pending-counter on
  the Approvals heading plus a toast when a new pending approval appears.
  Full setup, payload, signature verification and receiver recipes:
  [Notifications.md](Notifications.md).
- **Token minting is secret-bound.** `POST /token` mints only with the
  delegation's agent secret; minting for legacy delegations without a digest
  requires `TOKENSVC_ALLOW_NO_SECRET_MINT=1` (dev only — leave unset).

- **Public endpoints are rate-limited per client IP.** `POST /token` and
  `/token/exchange` default to 60 req/min (`TOKENSVC_RATE_LIMIT_PER_MIN`),
  `GET /oidc/login` to 30 req/min (`WEB_RATE_LIMIT_PER_MIN`); excess requests
  get `429` + `Retry--After`. Set the variable to `0` to disable.
- **Postgres and Redis are not published to the LAN** in the demo compose —
  only the services reach them over the compose network.
- **Supply-chain scans are clean.** `govulncheck` (Go toolchain 1.26.9 +
  current x/net, x/text) and Trivy (HIGH/CRITICAL, all four images: OS
  packages, service binaries, the unpack tool, the OPA engine) report zero
  findings.

Scan note: an OWASP ZAP baseline + full scan against the console and the
three core APIs reports **zero fails**; the remaining warnings are accepted
informational noise — cacheability of 302 redirects, session-management
detection on the OIDC flow, `script-src 'unsafe-inline'` in the CSP (pages
ship inline scripts; nonce-based CSP is follow-up work), the words
"user"/"token" appearing in benign JS comments, and the IdP-proxy responses
relayed from Dex. Under active scan, an anonymous client can reach only
`/api/config` (public metadata) — every actionable API answers 401, and
POST-only APIs 404. Re-run both against your own deployment after changing
any exposure:
`docker run --rm --network host zaproxy/zap-stable zap-baseline.py -t http://<host>:8083/ -r report.html`.
The playground's full journey (SSO sign-in → session-gated probe delegation →
probes → broken-edit rejection → hot reload → restore) is covered by a checked-in
end-to-end test: from the agent-gateway repo run `make e2e-playground` while
this stack is up.

---

## 6. Enterprise-grade production deployment

### 6.1 Persistence tier — the first thing to change

Memory-only persistence means state is lost on restart and cannot be shared
between replicas. Production always uses:

```yaml
environment:
  - PERSISTENCE=postgres
  - DATABASE_URL=postgres://agentgw:secret@postgres:5432/agent_gateway?sslmode=disable
  - REDIS_URL=redis://redis:6379/0
```

* The Postgres schema (`delegations`, `approvals`, `audit_events`) is created
  and version-migrated automatically on service start-up — **no separate
  migration job**. Multiple replicas starting concurrently are safe.
* Redis powers: instant jti (token-id) revocation that reaches enforcement in
  milliseconds even for tokens that are still cryptographically valid, and the
  optional decision cache.
* Keep Redis even when you do not need revocation latency — services log a
  warning per request when Redis is configured but unreachable, and revocation
  silently degrades to "deleted delegation" checks (which still work via the
  database in `authz`).

### 6.2 High availability thesis

All four services are **stateless** with `PERSISTENCE=postgres`:

| Component | HA pattern |
|---|---|
| `gateway`, `tokensvc`, `authz` | N identical replicas behind an internal load balancer. No sticky sessions required — no server-side session state exists. Scale the gateway to absorb your agent traffic; two replicas each of authz/tokensvc are usually sufficient. |
| `web` | 1–2 replicas behind your TLS terminator (external LB). Cookie-based OIDC state means any replica can validate the callback. |
| Postgres | Use a managed HA instance (AWS RDS/Aurora, Azure Flexible Server, Cloud SQL) or an operator like CloudNativePG / Zalando. Regular point-in-time recovery, backups of the `audit_events` table matter — it is your legal record. |
| Redis | Managed Redis (ElastiCache/Azure Cache) with `appendonly yes`, or a sentinel cluster. Losing Redis is survivable (revocation falls back to database lookups), but do not run a memory-only Redis in production for revocation consistency. |

### 6.3 Kubernetes example

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: agent-gateway-runtime
type: Opaque
stringData:
  jwt_secret: "<openssl rand -hex 32>"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: agent-gateway-gateway
spec:
  replicas: 3
  selector: { matchLabels: { app: agent-gateway-gateway } }
  template:
    metadata:
      labels: { app: agent-gateway-gateway }
    spec:
      containers:
        - name: gateway
          image: stevef1uk/agent-gateway-gateway:1.0.24
          ports: [{ containerPort: 8080 }]
          env:
            - name: PERSISTENCE
              value: postgres
            - name: DATABASE_URL
              valueFrom: { secretKeyRef: { name: agent-gateway-db, key: url }}
            - name: REDIS_URL
              value: redis://redis:6379/0
            - name: AUTHZ_URL
              value: http://agent-gateway-authz:8081
            - name: JWT_SECRET
              valueFrom: { secretKeyRef: { name: agent-gateway-runtime, key: jwt_secret }}
            - name: UPSTREAM_URL
              value: https://tools.internal.corp
          volumeMounts:
            - { name: customer-key, mountPath: /keys, readOnly: true }
            - { name: licence,      mountPath: /licences, readOnly: true }
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 10
          livenessProbe:
            httpGet: { path: /healthz, port: 8080 }
            periodSeconds: 15
          resources:
            requests: { cpu: 250m, memory: 256Mi }
            limits: { cpu: "1", memory: 512Mi }
          # Decrypt-and-run needs writable scratch space:
          volumeMounts: [{ name: scratch, mountPath: /tmp }]
      volumes:
        - name: customer-key
          secret: { secretName: agent-gateway-customer-key }
        - name: licence
          secret: { secretName: agent-gateway-licence }
        - name: scratch
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata: { name: agent-gateway-gateway }
spec:
  selector: { app: agent-gateway-gateway }
  ports: [{ port: 8080, targetPort: 8080 }]
```

* Secrets must contain per-service licences using the exact expected names:
  `authz.token`, `tokensvc.token`, `gateway.token`, `web.token` (for secret
  keys) so each container finds its file at `/licences/<service>.token`.
* Do the same for authz/tokensvc/web deployments.
* The `gateway` container decrypts into `/tmp`, so if you harden with
  `readOnlyRootFilesystem: true` you must provide a writable `emptyDir` at
  `/tmp` (both the images install curl and tzdata; no other write paths exist).

### 6.4 Upgrades

1. Pull the new image tag and recreate one service at a time
   (`web` → `tokensvc` → `authz` → `gateway`). Rolling restarts are safe
   because state lives in Postgres/Redis; `schema_migrations` makes schema
   upgrades automatic and idempotent.
2. Keep `JWT_SECRET` stable across upgrades — order flow is halted (401s)
   only if you regenerate it; then existing agent tokens are invalidated.

### 6.5 Licence lifecycle

A licence token is a vendor-signed file carrying an expiry date. When your
licence is nearing expiry the vendor issues a replacement file.

```bash
# swap the licence and restart — groups all four services
cp new.license.token keys/license.token
docker compose restart authz tokensvc gateway web
```

An expired licence produces a clear start-up failure (see §8), so an outage
cannot happen silently. Plan for a licence-renewal runbook ticket 30 days
before expiry.

---
### 6.6 Reinstalling on a new k3s cluster

If you need to deploy Agent Gateway to a fresh k3s cluster, the core resources
are portable, but these items must be in place first:

**Ingress controller** — Traefik (or equivalent) with `ingressClassName: traefik`
configured. Install with:
```bash
kubectl apply -f https://traefik.io/traefik.yaml
```

**cert-manager** with a `ClusterIssuer` named `letsencrypt-prod` (for TLS). Quick
install:
```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.0/cert-manager.yaml
# Then create the ClusterIssuer (HTTP-01 or DNS-01 challenge)
```

**Required secrets** in the `agentgw` namespace:
- `agentgw-telegram` (keys: `bot_token`, `chat_id`) — for approval Telegram cards
- `agentgw-keys` (keys: `license.token`, `customer_private.pem`) — licence + decryption key
- `agent-gateway-runtime` (key: `jwt_secret`) — shared 32-byte HMAC secret
- Any other secrets your deployment references (`POSTGRES_PASSWORD`, `JWT_SECRET`, `GATEWAY_ADMIN_TOKEN`)

**Supporting services** — Postgres 14+ and Redis 7+ (if `PERSISTENCE=postgres`).
The deployment creates the Postgres schema automatically on first start.

**Docker-pulled images** — multi-arch tags under `stevef1uk`:
- `stevef1uk/agent-gateway-gateway:1.0.28` (OAuth layer + per-tool MCP enforcement)
- `stevef1uk/agent-gateway-mcpsrv:1.0.1` (CRM MCP server with `find_customer` + `delete_customer`)
- `stevef1uk/agent-gateway-authz:1.0.12` (authorisation service)
- `stevef1uk/agent-gateway-tokensvc:1.0.5` (token minting)
- `stevef1uk/agent-gateway-web:1.0.44` (admin UI)

**DNS** — `agw.sjfisher.com` must resolve to the k3s cluster IP (A record) or a
CNAME to a reachable hostname. The ingress watches this host for OAuth callbacks
and Let's Encrypt challenges.

**k3s manifest deployment**:
```bash
kubectl apply -f k3s/agentgw.yaml
# Then verify:
kubectl -n agentgw get pods -l app=gateway-mcp
kubectl -n agentgw get ingress agentgw-ingress
# Test (resolve hostname to cluster IP first):
curl -k --resolve agw.sjfisher.com:443:<cluster-ip> https://agw.sjfisher.com:443/healthz
```

**Provision the connector's delegation (before first Claude connect)** — run
`k3s/create-claude-delegation.sh` (see [Claude-Integration.md](Claude-Integration.md)
for why the console form is insufficient): it mints a verified ID token,
creates a delegation with the discovery actions (`initialize`, `list`) plus
your tool names, an approval rule on destructive tools, a 12-hour TTL
(agent-configurable), and rebinds it to the subject your browser sign-in
actually uses. Auto-bind in the OAuth flow requires **exactly one** active
delegation — `--replace` revokes previous ones for the same agent first.

**Adding more MCP servers under the same Ring** — `k3s/add-mcp-server.sh <name>`
(verified end-to-end; see [Integration-Patterns.md](Integration-Patterns.md)
Pattern C) generates each server ClusterIP-only + a dedicated PEP instance +
its ingress path + path-scoped delegation, and saves the manifest
(`k3s/mcp-<name>.yaml`) so the new server is committed code.

**Post-deploy verification**:
- `GET /healthz` on each service returns `{"status":"ok"}`
- OAuth flow: add `https://agw.sjfisher.com/mcp` as custom connector in claude.ai,
  complete sign-in, verify `tools/list` and `tools/call add_customer`
- Approval flow: "delete that customer" → 202 hold → approve via Telegram card or
  console at `https://agw.sjfisher.com` → executes once
- Audit: `SELECT ts, agent_id, tool, action, outcome, reason FROM audit_events
    WHERE resource LIKE '/mcp%' ORDER BY ts DESC LIMIT 20;`

*Tip: the `k3s/agentgw.yaml` manifest in this repo already includes all the
Deployments, Services, Ingress and Dex config. The only cluster-specific items
are the ingress controller, cert-manager + issuer, DNS, and the secrets listed
above.*

## 7. Integrating with enterprise systems

### 7.1 Postgres — schema you can extend

```sql
delegations(id, user_id, agent_id, expires_at, revoked_at, created_at, data jsonb)
approvals (id, delegation_id, action_hash, status, approver_id, created_at,
           expires_at, decided_at, consumed, consumed_at, data jsonb)
audit_events(id, ts, request_id, user_id, agent_id, delegation_id,
             identity_from, tool, resource, action, tenant, args_hash,
             outcome, reason, policy_id, approval_id, approver_id,
             status_code, duration_ms)
```

Use these tables for BI/Compliance reporting; copy or stream `audit_events`
into your SIEM (Splunk, QRadar, Sentinel) with any Postgres CDC/ETL tool
(Debezium, Airbyte, pg_sync). Every allow/deny/approval becomes a row.

### 7.2 OIDC — bring your own IdP

Set on `authz` (and `web` for humans using the console):

```yaml
environment:
  - OIDC_ISSUER_URL=https://tenant.okta.com       # exact /issuer advertised
  - OIDC_CLIENT_ID=agent-gateway
```

Notes collected from real integrations:

* The **issuer string must be byte-identical** to what your IdP advertises in
  `/.well-known/openid-configuration` — redirect host names count. Point to
  discovery URL of the actual tenant, not a load balancer that might resolve
  differently (failures surface as `oidc discovery against "<url>"`).
* The ID token must carry `aud = OIDC_CLIENT_ID`.
* Admin web UI — register your deployment's callback:
  `https://<your-web-host>/oidc/callback`.
* For high-SSO domains (Okta, Entra ID, Keycloak) keep the default discovery
  interval; rotation of the IdP's signing keys is picked up verbatim.
* Dex (bundled in `deploy/dex`) is a reference on-prem OIDC provider if you
  want to keep identity on your network.

### 7.3 SPIFFE / SPIRE — zero-bearer-token agent identity

For platforms where agents already hold a workload identity, run the gateway
in mTLS mode instead of bearer tokens:

```yaml
environment:
  - ENABLE_SPIFFE=true
  - SPIFFE_WORKLOAD_API=unix:///run/spire/sockets/agent.sock
volumes:
  - type: bind
    source: /run/spire/agent-sockets
    target: /run/spire/sockets
```

The gateway then exposes a TLS listener and reads each agent's verified
SPIFFE ID from its X.509 SVID; the delegation connects an agent identity to
rights, and no token ever appears on the wire. Order of ops: run SPIRE agent
as a sidecar, then mount the workload API socket, then start the gateway.

### 7.4 Placement of the gateway

Existing agents already call back ends and MCP servers directly — the
migration patterns for inserting this gateway without rewriting them
(one-line config swap, DNS-level insertion, MCP fronting, egress control,
legacy-credential handling) are in
[Integration-Patterns.md](Integration-Patterns.md).

Decide where enforcement happens in your traffic path:

* **Inlined gateway (recommended)** — agents call the gateway; it forwards
  allowed requests to `UPSTREAM_URL`. One extra hop protects many tools.
* **Sidecar** — deploy one gateway next to one tool, each tool with its own
  licence, delegation rules, independent blast radius.
* **Library** — for Go-native teams: the `internal/gateway` package can be
  called as a library without a sidecar container; containerization is then
  only for licencing and binaries you want separated from your app.

---

## 8. Troubleshooting

| Symptom (exact startup/log text) | Cause | Fix |
|---|---|---|
| `No licence token found at /licences/<svc>.token` | Licence mount missing | Mount the token file per service with the right name |
| `ERROR: Licence has expired on <date>` | Licence past expiry | Obtain a new licence from your vendor; replace, restart |
| `license required: provide -license-token <path>` | Licence present but no `-license-token` was passed by the entrypoint (env overridden?) | Do not override `LICENCE_TOKEN_PATH` unless you know what you are doing |
| `Customer private key not found at /keys/customer_private.pem` | Key not mounted | Mount `customer_private.pem` read-only at `/keys` |
| `Encrypted payload <svc>.enc not found` | Wrong image build or a stripped image | Re-pull the vendor image |
| `open backends: redis ping: dial tcp … connection refused` | Redis URL unreachable from inside the network | Use the service/DNS name, not `localhost`; check Redis is running |
| `migrate: …` on `authz`/`gateway` | Postgres down or credentials bad | Check `DATABASE_URL`; ensure DB exists and has ACLs |
| `oidc discovery against "<url>"` | IdP unreachable, or issuer string mismatch | Fix `OIDC_ISSUER_URL`, verify with `curl <issuer>/.well-known/openid-configuration` |
| `user identity could not be verified: … no ID token presented` | Delegation created without an ID token while OIDC is enabled | Sign in via web UI, or pass the `id_token` in the delegation request body |
| Gateway `401 unauthorized: authorization scheme must be Bearer` | Missing/wrong auth header | Use `Authorization: Bearer <agent token>` |
| Gateway `403` after a delegation revoke | Working as intended — revocation is enforced instantly | Obtain a new delegation |
| tokensvc `delegation unavailable` / `dial … :8081 refused` | `AUTHZ_URL` wrong inside your network | Use the compose/K8s service DNS name |

Health endpoints — `GET /healthz` on every service — return
`{"status":"ok"}`; wire them into your orchestrator probes (§6.3) and your
monitoring. Service logs are plain JSON on stdout suitable for any log shipper
(Fluentd/Filebeat → ELK/CloudWatch).

---

## 9. Operations checklist (print this)

* [ ] `JWT_SECRET` set to a random 32-byte value on authz, tokensvc, gateway
* [ ] `PERSISTENCE=postgres` with a managed, HA database
* [ ] `REDIS_URL` set; append-only / managed instance
* [ ] `OIDC_ISSUER_URL` set to your enterprise IdP
* [ ] Licence token for each service mounted read-only; renewal date in your calendar
* [ ] `customer_private.pem` stored as a secret, never in images; never commited
* [ ] `UPSTREAM_URL` pointing at your real tool backend
* [ ] `audit_events` streamed to your SIEM
* [ ] TLS terminating at the web UI / gateway LB (the container listeners are
      plain HTTP by design to sit behind your own TLS termination — or use
      SPIFFE mTLS mode for end-to-end encryption)
* [ ] `docker compose pull` with pinned image digests scheduled for upgrade windows

---

*Questions or issues with your licence: contact your vendor support channel
with the output of `docker compose logs <svc>` and your licence expiry date.*

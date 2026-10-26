# Bringing existing agents under the gateway

*"Our agents were written before the gateway existed — they call MCP servers
and back-end REST endpoints directly, with credentials embedded. How do we
insert the PEP without touching every agent?"*

The gateway was designed for this: it is a **pass-through reverse proxy with
policy identity**, and its default semantics come from plain HTTP itself
(`/path` = resource, HTTP verb = action, first path segment = tool name —
`internal/gateway` derives these; `X-Agent-*` headers are optional overrides).
Agents need no gateway-specific code at all: whatever they already send on
the wire, the gateway can authorise and forward, adding the decision, the
hold-for-approval gate and the audit record around it.

> **Deciding what to put in the delegation?** See
> [Protecting-Your-API.md](Protecting-Your-API.md) for the full catalogue of
> constraints (scope patterns, spend/count limits, approval rules) and which of
> them the built-in engine enforces directly vs. which need OPA.

## The five integration patterns

### Pattern A — base-URL cutover (the one-line change)  *recommended first*

Agents read their tool endpoints from configuration (env var, settings file,
MCP client config). Point that configuration at the gateway instead of the
back end and hand the agent one delegation token to put in
`Authorization: Bearer …`:

```
Before:  BASE_URL=https://orders.internal.corp          (agent calls directly)
After:   BASE_URL=https://agent-gateway.internal.corp/orders
         TOKEN=<the agent's delegation token>
```

Why this is realistic: every agent framework takes its tool locations from
configuration — the *deployment artifact* changes, the agent's logic does not.
Delegations are per agent/team, created in the admin console; the audit trail
then shows every legacy agent's traffic with a name, an owner and a scope.

### Pattern B — transparent network insertion (zero agent change)

For fleets you cannot reconfigure: cut over at the network layer instead.

```
DNS/VIP change:   orders.internal.corp  →  formerly the backend,
                  now resolves to the gateway, upstream routed internally
```

Agents keep calling the same hostname with their existing code path. What
changes for them: responses come back 401 until they present credentials that
the gateway accepts. So roll this gradual: per tool, page the owner, hand
their agent a delegation token, flip the DNS. The gateway's audit trail gives
you the coverage map: every 401 has an unauthed caller behind it.

### Pattern C — MCP servers

MCP traffic is JSON-RPC over HTTP (streamable HTTP/SSE transports), and the
MCP client is always configured with the *server URL* — the same leverage as
Pattern A: point the client at the gateway, put the real MCP server behind it
as `UPSTREAM_URL`.

**Per-tool enforcement works today**: the gateway parses the MCP JSON-RPC
body at the enforcement point — for `tools/call` the action is the invoked
**tool name** and the full argument object feeds caps, approval rules and the
exact-action hash; discovery calls (`server/discover`, `tools/list`,
`resources/*`, `prompts/*`) authorize as `initialize`/`list`. Delegations
therefore scope MCP per tool (`actions: ["initialize","list",
"add_customer",…]`), approval rules match tool names, holds/denies arrive as
JSON-RPC envelopes real clients render, and `tools/list` is filtered per
delegation (visibility only — calls are always re-authorized).

| Enforcement level | What you get | How |
|---|---|---|
| Per **server** (day one) | every MCP session against that server is governed: delegation, scope, cap, audit, approval gate | gateway fronts the MCP server; JSON-RPC calls arrive as ordinary HTTP |
| **Per tool** (delivered — the default now) | each `tools/call` judged by its own `params.name` → tool-scoped policy | the MCP filter in the gateway parses the JSON-RPC body and re-derives resource/action per call |

For self-operated MCP servers there is a variant worth knowing: wrap the MCP
server with the gateway agent middleware (a thin server that requires the
delegation JWT before forwarding) if you prefer enforcement to live next to
the server rather than in front of it.

> **Claude, Inspector, Cursor — the OAuth connector path.** MCP clients that
> connect remotely (claude.ai's custom connector, Claude Desktop, MCP
> Inspector…) obtain their credential through the gateway's own OAuth
> authorization server (dynamic registration + PKCE against your identity
> provider), then every call is enforced per tool — the complete user/ops
> guide is [Claude-Integration.md](Claude-Integration.md); Demo 9
> ([Demos.md](Demos.md)) runs a CRM MCP server through all three enforcement
> levels via k3s (manifest k3s/agentgw.yaml); `./demo/mcp-oauth-demo.sh`
> replays the connector flow against the k3s deployment.

> **Hands-on recipe for protecting YOUR MCP server** — dedicated gateway
> instance, delegation JSON, client config, the delete-approval pattern and
> the honest limitations — lives in
> [Protecting-Your-MCP.md](Protecting-Your-MCP.md).

#### Many MCP servers under one Ring

**One PEP process per server — one Ring** (the same gateway image + the
same policy engine everywhere; the Ring is the *invariant* — no MCP client
reaches any MCP server without crossing a PEP and a delegation — not a
single process count):

```
          ┌────────── ONE EXTERNAL HOST: https://mcp.example.corp ──────────┐
          │  Ingress (traefik, one Let's Encrypt cert, one issuer identity)  │
          └──┬──────────────┬───────────────┬──────────────────┬────────────┘
             │ /mcp         │ /mcp-finance  │ /oauth /.well-known    / → console
   ┌─────────▼─────┐  ┌─────▼──────────────┐   │
   │ gateway-mcp   │  │ gateway-mcp-finance│   │            ← same image,
   │ (PEP for CRM) │  │ (PEP for finance)  │   │              same OAuth layer,
   │ UPSTREAM=crm  │  │ UPSTREAM=finance   │   │              same delegation
   └───────┬───────┘  └─────────┬──────────┘   │              engine, one audit
           │ allowed only       │ allowed only │              ledger
   ┌───────▼───────┐  ┌────────▼──────────┐   │
   │ crm MCP server│  │ finance MCP server│   │
   │ ClusterIP only│  │ ClusterIP only    │   │
   └───────────────┘  └───────────────────┘   │
       both UNREACHABLE from outside ─────────┘
```

**Why per-instance (the design reasoning):**

1. `UPSTREAM_URL` is instance-level by design — path/action derivation is
   rooted in the one protected back end per PEP.
2. **Failure isolation** — a flaky upstream cannot take MCP governance down
   with it.
3. **Policy arrives by path** — `/mcp-finance` routes to its PEP, so its
   `tools/call`s authorize against delegations scoped `/mcp-finance*`; the
   CRM's grants can never spend another server's capabilities.
4. **The cost is small** — each PEP is ~10 lines of YAML, or one
   `./k3s/add-mcp-server.sh <name>` invocation (`IMAGE PORT TOOLS
   DELETE_PATTERN AGENT_ID`), which generates the ClusterIP-only server +
   dedicated PEP + the ingress path + the path-scoped delegation (calling
   `create-claude-delegation.sh`) and saves the manifest as code
   (`k3s/mcp-<name>.yaml`).

> *One hostname, one identity system, one audit ledger — many PEPs, one
> per protected server, each behind its own path.*

Verified end to end on this repo's k3s deployment: a second MCP server
behind `https://agw.sjfisher.com/mcp-second` (401 ungoverned-check, RFC
9728 challenge, subject-bound delegation). User-facing recipe:
[Claude-CRM-Tutorial.md](Claude-CRM-Tutorial.md).

### Pattern D — egress control so nobody can bypass

In enterprise topology the gateway is inserted only if agents *cannot* shadow
route around it. Standard belt-and-braces:

- Kubernetes `NetworkPolicy`: agent pods may egress **only** to the gateway;
  the gateway (or the mesh) is the only identity allowed to reach the back end.
- VM estates: egress firewall rules per agent segment, same principle.
- Regular expression review of the audit trail: tool names appearing without a
  gateway request id are a bypass signal.

This is what turns "we prefer agents use the gateway" into "agents go through
the gateway," which is also what the auditors will ask for.

### Pattern E — Public Web Frontends & Backend Proxy (BFF)

When you want a public-facing website, SPA, or mobile frontend to invoke an MCP
server (such as an interactive demo or customer-facing AI feature), **never embed
gateway credentials (`agent_secret`, `delegation_id`, or long-lived Bearer tokens)
into client-side JavaScript or HTML**. Anyone inspecting the page can extract the
credentials and invoke unauthorized tools, bypass quotas, or drain spend caps.

Instead, insert an ultra-lightweight Backend Proxy (or Backend-for-Frontend / BFF
pod) between the browser and the Agent Gateway:

```
┌─────────────────────────────────────────────────────────────┐
│  PUBLIC BROWSER / STATIC HOSTING                            │
│  (DigitalOcean, Cloudflare Pages, S3, GitHub Pages)        │
│                                                             │
│  index.html: fetch("https://preprod.agw.example.com/api/emotion/analyze", { text })
└──────────────────────────────┬──────────────────────────────┘
                               │ POST /api/emotion/analyze (CORS: *)
                               ▼
┌─────────────────────────────────────────────────────────────┐
│  K3S INGRESS & REWRITE (Traefik)                            │
│  • Middleware: emotion-cors (Access-Control-Allow-Origin: *)│
│  • Middleware: emotion-ratelimit (10 req/min, burst 3 / IP) │
│  • Middleware: emotion-inflight (max 2 concurrent requests) │
│  • Middleware: emotion-rewrite (/api/emotion/* → /api/*)    │
└──────────────────────────────┬──────────────────────────────┘
                               │ POST /api/analyze
                               ▼
┌─────────────────────────────────────────────────────────────┐
│  BACKEND WEB PROXY POD (ClusterIP only)                     │
│  • Securely injects DELEGATION_ID + AGENT_SECRET via Secret │
│  • TokenManager: Mints & auto-refreshes short-lived Bearer  │
│    tokens from https://preprod.agw.example.com/token        │
│  • Maps REST payload {"text":"..."} to MCP tools/call JSON-RPC
└──────────────────────────────┬──────────────────────────────┘
                               │ Authorization: Bearer <cached_jwt>
                               │ tools/call {"name":"emotion_detection"}
                               ▼
┌─────────────────────────────────────────────────────────────┐
│  AGENT GATEWAY PEP (gateway-mcp-emotion)                    │
│  • Enforces delegation del-050d7ee83471a3ff90495cf6         │
│  • Validates tool actions ["emotion_detection", ...]        │
│  • Emits tamper-proof audit record                          │
└──────────────────────────────┬──────────────────────────────┘
                               │ allowed call
                               ▼
┌─────────────────────────────────────────────────────────────┐
│  BACKEND MCP SERVER (fine-tuned Gemma3 on ARM64)            │
└─────────────────────────────────────────────────────────────┘
```

#### How it works in practice:

1. **Clean Client Interface**: The public web page issues an unauthenticated
   `POST` with user inputs (e.g., text to analyze). No API keys, secrets, or
   tokens are present in the frontend.
2. **Cluster Secret Storage**: The proxy pod runs internally in Kubernetes with
   `DELEGATION_ID` and `AGENT_SECRET` loaded strictly from Kubernetes Secrets.
3. **In-Memory Token Cache**: A lightweight `TokenManager` in Go fetches a short-lived
   JWT from `/token`, caches it in memory with mutex locking, and refreshes it
   automatically 60 seconds before TTL expiration.
4. **JSON-RPC MCP Formatting**: The proxy wraps the incoming JSON into a standard
   MCP `tools/call` envelope and forwards it to the gateway PEP with `Authorization: Bearer <jwt>`.
5. **CORS & Path Decoupling**: Traefik middleware handles CORS preflights (`OPTIONS`)
   and rewrites paths so the static site (hosted on external domains like DigitalOcean)
   can connect seamlessly to the backend cluster without CORS errors.
6. **Edge Throttling & DoS Protection**: Because public AI demo backends (such as LLM
   inference on small nodes like Raspberry Pis) are CPU- and memory-intensive, ingress
   layers must prevent denial-of-service attacks. Traefik middlewares `rateLimit`
   (e.g., 10 req/min per IP with burst capacity of 3) and `inFlightReq` (max 2
   simultaneous concurrent requests) intercept traffic at the cluster perimeter and
   instantly reject abusive traffic with `HTTP 429 Too Many Requests` (complete with
   CORS headers) before abusive calls reach the proxy or LLM pod.

#### Live Reference Repositories & Working Code

This pattern is live in production running a fine-tuned Gemma 3 emotion detection
MCP server on a Raspberry Pi k3s cluster fronted by a public website:

* **Live Website**: [https://emotion-service-api.sjfisher.com](https://emotion-service-api.sjfisher.com)
* **Frontend Web Repo**: [stevef1uk/emotion-server-api](https://github.com/stevef1uk/emotion-server-api)
  * [`index.html`](https://github.com/stevef1uk/emotion-server-api/blob/main/index.html): Public web page calling the API without secrets.
  * [`proxy/`](https://github.com/stevef1uk/emotion-server-api/tree/main/proxy): Go proxy pod code (`main.go`, `token.go`, `Dockerfile`, `.env.example`).
* **Backend Deployment Repo**: [stevef1uk/emotion-server-demo](https://github.com/stevef1uk/emotion-server-demo)
  * [`src/web-proxy/`](https://github.com/stevef1uk/emotion-server-demo/tree/master/src/web-proxy): Go backend proxy implementation and test suite.
  * [`k8s/emotion-web.yaml`](https://github.com/stevef1uk/emotion-server-demo/blob/master/k8s/emotion-web.yaml): Deployment and ClusterIP service for the proxy.
  * [`k8s/emotion-ingressroute.yaml`](https://github.com/stevef1uk/emotion-server-demo/blob/master/k8s/emotion-ingressroute.yaml): Traefik CORS and path-rewriting IngressRoute.
  * [`k8s/create-gateway-secret.sh`](https://github.com/stevef1uk/emotion-server-demo/blob/master/k8s/create-gateway-secret.sh): Helper script to generate Kubernetes secret without writing secrets to disk.

## What about credentials already present in the agents?

Legacy agents carry their back-end credentials (API keys, service tokens).
Treatment options, in escalation order:

1. **Leave them; add ours.** The gateway requires the delegation token in
   `Authorization`; keep the back-end credential in another header the backend
   still accepts (the gateway forwards request headers). Fastest cutover, and
   the back end's own auth still works as your second gate.
2. **Rotate out.** Once the gateway is the front door, back-end credentials
   can be re-scoped to "issued to the gateway service account only", which is
   a security improvement the whole platform gets for free: agents no longer
   hold back-end creds at all — only delegation scopes.
3. **Credential translation (roadmap):** have the gateway accept an existing
   back-end credential *as the identifying credential*, mapped to a
   delegation, for cases where even adding one header is impossible. Same
   trust anchoring, zero agent change. This is an adapter, not a default.

## Migration runbook for an existing agent population

1. Inventory: enumerate agents from your deployment framework; for each
   produce `agent_id = <platform-env-agent-id>`.
2. Provision: create delegations per agent (one ceremony each; see
   [Agent-Identity.md](Agent-Identity.md)) with sensible scope and expiry.
3. Deliver credential: secret+distribution per agent (provisioning/store).
4. Configure: change the agent's tool base URL(s) to gateway routes
   (Pattern A), or flip DNS/VIP per tool for fleets (Pattern B).
5. Verify: the audit trail shows the agent name on its calls; any 401/403 is
   the agent needing config/credential fixes, not the gateway failing.
6. Harden: apply egress control (Pattern D); rotate out the legacy back-end
   credentials.

The same script — with `curl` examples — runs end to end at
[Demos.md](Demos.md); every claim in this document is executable against the
[demo stack](../demo/).

## What this buys you

Your back ends get **one front door** with: SSO-bound delegation, least
privilege, spend caps, human approval on dangerous actions, instant
revocation, and a forensic-quality audit trail — for agent fleets you never
recompiled, only re-pointed.

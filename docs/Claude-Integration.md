# Claude + Agent Gateway (MCP One Ring)

> *"One Gateway to rule them all."*
>
> Claude's custom remote connectors can call your MCP servers **through the
> Agent Gateway**: every tool call is identified, checked against a human's
> **delegation**, audited, and — for what you mark risky — **held until a
> named human approves**, before anything executes.
>
> **Status: verified end to end** (MCP Inspector conformance + a live
> claude.ai connector pass on record; k3s deployment with DNS + TLS see
> below; see the demo scripts below).
>
> For a step-by-step screenshot walkthrough of the user experience —
> connect, add a customer, delete held + approved — see
> [Claude-CRM-Tutorial.md](Claude-CRM-Tutorial.md).

## What you get

| Without the gateway | With the gateway between Claude and your MCP servers |
|---|---|
| anyone/anything that reaches the port can call `delete_customer` | calls are refused without a **verified, delegated identity** |
| no record of who did what | **one audit row per call**: verified human subject + client application (`client_id`) + agent + delegation + tool + decision |
| destructive actions run on the model's say-so | risky tools **hold (202)** until the delegating human approves — single-use, bound to the exact action (tools + arguments), tamper-proof |
| "we told the agent to be careful" is your control | **revocation is instant** — even a valid, unexpired token (or a rotating refresh) dies at the next call |

**The differentiator is not "Claude can call a tool" — it is who authorizes
what happens after that tool call.**

## How to connect (user view)

In **claude.ai** (or Claude Desktop / Cowork):

1. Settings → **Connectors → Add custom connector**
2. Give the gateway's MCP endpoint URL — e.g. `https://agw.sjfisher.com/mcp`
   (must resolve to your k3s cluster; DNS + Let's Encrypt TLS required)
3. The OAuth popup opens: sign in at **your** identity provider (Dex demo is
   one click; Okta/Entra/Keycloak work through the same flow)
4. Pick or confirm the **delegation** the connector may use (one active
   delegation binds automatically; several → chooser; none → nothing granted)
5. Chat: "add a customer" — the tool call executes, authorized + audited;
   "delete that customer" — **the gateway holds it for your approval**, Claude
   relays the hold honestly, and retrying after you approve executes exactly once.

## The flow (ops view)

```
Claude connector ──401 + WWW-Authenticate──► discovery (RFC 9728/8414 documents)
        │
        ▼
Dynamic client registration (RFC 7591)       POST /oauth/register
Authorization code + PKCE S256               GET  /oauth/authorize
        │   the human signs in at YOUR IdP (the gateway relays cluster-internal
        │   providers via /oauth/idp/* — the IdP's own hostname stays internal)
        ▼
Human binds an ACTIVE delegation they own    (server-side; never client-chosen)
        │
        ▼
Access token = ordinary delegation-scoped JWT      (+ rotating refresh that
        │                                           re-checks delegation liveness)
        ▼
MCP JSON-RPC over Streamable HTTP            POST /mcp — enforced per tool:
        action = the TOOL name (parsed from the JSON-RPC body);
        discovery (server/discover, tools/list…) authorize as list/initialize;
        spend caps + approval rules + the exact-action hash work per call
```

Details: `one_ring_design.md` (phases) and `docs/Identity-Model.md` in the
source repository — who proves what, and the audit attribution contract.

## Try it — two deployment tracks

### Track A — docker compose + quick tunnel *(start here; five minutes)*

The laptop path: the stack runs under compose, a cloudflared quick tunnel
gives the OAuth layer a public HTTPS issuer, and everything just works.

```bash
cd demo && docker compose up -d   # 7 containers (gateway-mcp on :8085)
./oauth-tunnel.sh                 # tunnel + Dex wiring + discovery check
# → add https://<tunnel-url>/mcp as the custom connector in claude.ai
# → ./oauth-tunnel.sh --kill stops it (quick tunnels renumber on restart)
```

Then provision the delegation (below — one script) and click **Connect**
in claude.ai. Verify the full add/hold/approve/delete loop.

### Track B — k3s with a real DNS name *(durable; the Phase-4 path)*

The cluster path: gateway-mcp + the MCP server run as Deployments behind an
Ingress with a Let's Encrypt certificate — no tunnel, a name you can keep.

Full checklist (ingress controller, cert-manager, secrets, DNS):
[Deployment-Guide.md §6.6](Deployment-Guide.md#66-reinstalling-on-a-new-k3s-cluster).
The manifest is `k3s/agentgw.yaml`:

- **Ingress** `host agw.<your-domain>`: `/mcp`, `/oauth`, `/.well-known` →
  `gateway-mcp:8080`; `/` → `web:8083` (console) — one LE cert covers all
- **Dex config** (ConfigMap `dex-config`) needs **both** redirect forms
  registered: `https://agw.<your-domain>/oauth/idpcallback` (the MCP
  connector's OAuth callback) and `https://agw.<your-domain>/oidc/callback`
  (the console's sign-in callback). Missing either is an "Unregistered
  redirect_uri" 400 at sign-in.
- **DNS**: `CNAME agw.<your-domain> → k3s.<your-domain>` (the cluster ingress
  IP); the Let's Encrypt HTTP-01 challenge completes once DNS resolves.
- **Not** a NodePort: the MCP server is ClusterIP-only (an ungoverned MCP
  server reachable without the gateway is the whole failure mode Demo 9
  shows), and gateway-mcp is reached through the ingress only.

### The delegation (both tracks) — run before hitting Connect

The connector auto-binds **exactly one active delegation** — it must exist,
be valid, and carry the right shape. Three traps the admin console form
cannot avoid:

1. **Discovery actions** — `initialize` and `list` must be in `actions`
   besides the tool names; without them every call (incl. the connector
   handshake) is denied, and Claude reports *"Couldn't connect to the
   server"*.
2. **TTL** — the console form hardcodes 1800 s; the delegation expires
   between attempts and Claude reports *"No active delegation exists for
   your account"*. Use hours, not minutes.
3. **Subject binding** — a delegation is owned by the verified subject of
   the ID token used to create it; a password-grant subject and the
   browser's sign-in subject can differ for the same human, and
   subject-mismatched rows are invisible where it matters.

```bash
# k3s (Track B) — proven end-to-end on agw.sjfisher.com:
./k3s/create-claude-delegation.sh            # defaults: claude-mcp, 12h, all traps handled
./k3s/create-claude-delegation.sh --replace  # revoke previous first (auto-bind needs ONE active)
# compose (Track A): create via the console UI, then UPDATE the row:
#   actions   := ["initialize","list", <your tools>]
#   expires_at in hours; user_id := the subject of YOUR browser sign-in
```

Script knobs (`TOOL_ACTIONS`, `DELETE_PATTERN`, `AGENT_ID`, `TTL`,
`OAUTH_SUBJECT`) cover your own tool names; all env-overridable.
```

Demo 9 (`./mcp-demo.sh`) shows the same MCP server at three enforcement
levels (unprotected / PEP-protected / agent-driven) plus the approval
story on a destructive tool.

## Deployment knobs (gateway environment)

| Variable | Meaning |
|---|---|
| `OAUTH_ENABLED=1` | turn the OAuth layer on (requires `OIDC_ISSUER_URL`) |
| `OAUTH_ISSUER_URL` / `OAUTH_PUBLIC_BASE` | the issuer **browsers and claude.ai reach** (public HTTPS) |
| `OAUTH_IDP_RELAY=0` | for public IdPs (Okta/Entra) whose issuer is already browsable |
| `OAUTH_IDP_BROWSER_URL` / `OAUTH_IDP_CLIENT_ID` | override the provider hop / client identity |
| `OAUTH_TOKEN_TTL` / `OAUTH_REFRESH_TTL` | connector token lifetimes (default 5m / 8h) |
| `APPROVAL_TELEGRAM_*` / `APPROVAL_CONSOLE_URL` | **hold cards + deep link** — wire these or humans must watch the console. Telegram cards land **in the operator's chat only**: the bot token and chat id are the infrastructure owner's, so whoever runs the gateway is the notified approver; other humans decide via the console (`APPROVAL_CONSOLE_URL`). Per-user notification channels are roadmap. |
| `UPSTREAM_URL` | upstream MCP server URL (e.g. `http://mcpsrv:8091`, NOT published) |
| `OAUTH_ENABLED=1` | turn the OAuth layer on (requires `OIDC_ISSUER_URL`) |

## Honest limits (so nothing over-promises)

- **claude.ai's connector connects from Anthropic's infrastructure**: the
  issuer must be publicly reachable HTTPS (tunnel for testing; a real
  domain + certificate for anything durable — Phase 4).
- **OAuth state is in-memory this phase** (registrations, flows, codes,
  refresh tokens): single-replica deployments; a gateway restart
  invalidates connectors' cached registrations — reconnect re-registers.
- **Discovery filtering is visibility**: `tools/list` is narrowed per
  delegation, but every `tools/call` is independently authorized — hiding
  a tool is not a control, denying it is.
- **In-memory CRM note**: the demo MCP server's store resets on container
  restart; approvals persist (Postgres), the customers do not.
- **DPoP (RFC 9449) and RAR (RFC 9396)**: Fully implemented in core Agent Gateway.
  Tokens can be sender-constrained to agent-held keys (`cnf.jkt`) and downscoped
  to fine-grained action, resource, and limit structures (`authorization_details`).
  See [DPoP-and-RAR.md](DPoP-and-RAR.md).

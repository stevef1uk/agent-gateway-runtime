# Protecting an MCP server with Agent Gateway (hands-on)

> *"We have agents (Cursor, OpenClaw, our own runtime — whatever) that talk
> to MCP servers. What stops an agent from doing something it shouldn't, and
> who would even know?"*

This is the practical answer for **your** MCP servers. The worked version of
every step below is **Demo 9** (`./demo/mcp-demo.sh`, see
[Demos.md](Demos.md#demo-9--mcp-under-the-gateway-demo_mcp-demosh-openclaw-edition));
this page is the recipe you would follow for a real deployment. The demo
stack is now deployed to k3s (manifest k3s/agentgw.yaml) instead of docker
compose, but the delegation, approval and audit flow is identical.

## The idea in one paragraph

Point the agent's MCP client at **the gateway instead of the MCP server** —
one URL change in the agent's MCP config — and hand the agent a *delegation
token* instead of nothing (or instead of your server's real credentials).
The gateway proxies standard MCP (streamable-HTTP): it identifies the agent,
checks the human's delegation, audits every call, and — for operations you
mark as risky — **holds them for a named human's approval** before anything
executes. Your MCP server needs **zero gateway-specific code**; the agent
needs **zero code**. If you keep the MCP server's port unpublished, the
gateway is not just the front door — it is the *only* door.

## The three pieces, and the one you configure

| Piece | Needs changes? | What you do |
|---|---|---|
| The MCP server | **no** | it stays a standard MCP server |
| The gateway | light | point a gateway instance at it (`UPSTREAM_URL`), publish the PEP port |
| The delegation | **yes — this is the control** | the human's grant: scope, caps, approval rules, expiry |
| The agent | config only | swap the MCP server URL for the gateway URL; add one `Authorization` header |

### Quick note: on a k3s deployment the pieces below are one command

```bash
./k3s/add-mcp-server.sh <name>     # + env: IMAGE PORT TOOLS DELETE_PATTERN AGENT_ID
```

generates Deployment + ClusterIP Service for the MCP server, a dedicated
PEP instance (`gateway-mcp-<name>`, same OAuth layer and secrets), one more
Ingress path on the shared LE-cert'd host, prints (or provisions via
`create-claude-delegation.sh`) the delegation scoped to `/mcp-<name>*` and
the server's tool names. Each tool call is authorized against the
delegation matching the resource path it arrived on — many servers stay
safe on one hostname. The generated manifest is saved (`k3s/mcp-<name>.yaml`)
so the server is committed code, not console state. Users add the connector
`https://<host>/mcp-<name>` in claude.ai — same sign-in, separate identity
trail.

## Step 1 — put the gateway in front of the MCP server

`UPSTREAM_URL` (where the gateway forwards allowed calls) is set per gateway
instance, so the clean pattern — the one the demo stack uses — is **one
dedicated gateway instance per MCP server**:

```yaml
  my-mcp-gateway:                 # the PEP for MCP traffic only
    image: stevef1uk/agent-gateway-gateway:1.0.24
    ports: ["8085:8080"]          # what agents will point their MCP client at
    environment:
      - AUTHZ_URL=http://authz:8081
      - UPSTREAM_URL=http://my-mcp-server:8091   # your MCP server, NOT published to the network
      # ... same DATABASE_URL / REDIS_URL / JWT_* / GATEWAY_ADMIN_TOKEN as your other gateway
    volumes:
      - ./keys:/keys:ro
      - ./keys/license.token:/licences/gateway.token:ro
```

Your existing gateway (REST APIs, demoapi-style) keeps running untouched —
that is why the demo stack runs `gateway` (→ demoapi) and `gateway-mcp`
(→ mcpsrv) side by side.

**Do not publish the MCP server's own port.** In the demo you can `curl
:8091/customers` out of band *as the operator*, but agents never get that
route: an MCP server reachable without the gateway is an ungoverned server,
whatever the gateway says (Demo 9 Part A is exactly that sight).

## Step 2 — the delegation: the human's grant

After signing in at the console (SSO/OIDC), create the delegation for the
agent — in the UI, or with one call:

```json
{
  "agent_id": "my-shell-openclaw",
  "resources": ["/mcp*"],                 // the gateway's path to this MCP server
  "actions": ["read", "create"],           // what MCP work the agent may attempt
  "expires_in_seconds": 1800,
  "id_token": "<the human's verified ID token>"
}
```

* **`agent_id`** names the agent — audit rows carry it together with your
  verified identity.
* **`resources`/`actions`** — the least-privilege scope. The gateway
  **parses the MCP JSON-RPC body** at the enforcement point: for
  `tools/call` the action is the invoked **tool name** (`resource=/mcp`),
  and discovery authorizes as `initialize`/`list`. Scope MCP per tool:
  `"actions": ["initialize","list","add_customer","lookup_customer"]`
  (globs welcome). Unlisted tools are denied even if they reach the port —
  see the granularity note below.
* **`agent_secret`** in the response is shown **once** — that is the
  agent's credential to mint tokens, never a bearer token itself.

## Step 3 — give the agent its credential

Mint a short-lived token and hand it to the agent as a header — the token
TTL is what you choose at mint time (align it with the session):

```bash
TOKEN=$(curl -s -X POST http://localhost:8082/token -H 'Content-Type: application/json' \
  -d "{\"delegation_id\":\"$DELEG_ID\",\"ttl_seconds\":1800,\"agent_secret\":\"$SECRET\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
```

Then register the gateway URL as the agent's MCP server. OpenClaw example
(an ordinary remote streamable-http entry, like for any MCP server):

```json
"mcp": { "servers": { "my-crm": {
  "url": "http://<gateway-host>:8085/mcp",
  "transport": "streamable-http",
  "headers": { "Authorization": "Bearer ${MCP_DELEGATION_TOKEN}" }
}}}
```

Any MCP client with the standard remote-server shape works the same way:
URL + `Authorization: Bearer …` header. That already buys you: 401 for the
credential-less, identity + delegation + audit for the agent, instant
revocation (Step 6).

## Step 4 — make a dangerous operation human-approved

This is where the gateway earns enforcement beyond bookkeeping. The rule —
and its whole engine — lives in the **delegation**:

```json
"approval_rules": [{
  "when":   { "resource_pattern": "/customers*", "action_pattern": "delete" },
  "require": true,
  "rationale": "Deleting customer data: verify this is the right record before approving"
}]
```

How an operation becomes gateable: the gateway derives resource and action
from the wire — first path segment = resource, HTTP verb = action for REST,
and for MCP **from the parsed JSON-RPC body** (`action = the tool name`):
one approval rule can now target a tool directly, no REST side-channel
required (Demo 9 Part D's REST delete shows the classic shape):

| Wire call | derivation | rule match |
|---|---|---|
| `POST /mcp` (`tools/call add_customer`) | `/mcp` · `add_customer` | no → flows automatically, audited with the tool name |
| `POST /mcp` (`tools/call delete_customer`) | `/mcp` · `delete_customer` | **yes → HELD (202)**, upstream never called |
| `DELETE /customers/CUST-0005` (REST) | `/customers/CUST-0005` · `delete` | yes → HELD (202) |
| retry after approval (either path) | identical derivation/hash | executes **exactly once** |

On a hold, the human sees the card (console always, Telegram when wired)
with the rationale, and decides. The mechanics that make it safe:
**approver binding** (only the grant's creator may decide — a decision
without the delegating subject is refused), **single-use, exact-action**
(the decision binds the precise action hash — approving one delete never
blankets the next), and **sticky denial** (a deny outlives the delegation:
the same action from the same agent is refused on sight under a fresh
grant). All of it lands on the audit trail.

You can read the same rules as *policy-as-code*: constraints direct in the
delegation, richer ones (per-tenant, time-shaped) in OPA — see
[Policy-and-OPA.md](Policy-and-OPA.md).

## Step 5 — prove it, and take it away

```bash
# every MCP decision, with the agent's name and yours on it:
docker exec agent-gateway-postgres psql -U agentgw -d agent_gateway \
  -c "SELECT ts, agent_id, resource, action, outcome, reason FROM audit_events
      WHERE resource LIKE '/mcp%' ORDER BY ts DESC LIMIT 20;"

# revoke — even mid-session, even before the token expires:
curl -o /dev/null -w 'revoke → HTTP %{http_code}\n' -X DELETE \
  "http://localhost:8081/v1/delegations/$DELEG_ID" -H "Authorization: Bearer $ID_TOKEN"
# the agent's very next MCP call → 403, token still valid on the wire
```

## Honest limits today (so nothing over-promises)

* **Per-tool enforcement is delivered** — the gateway parses the JSON-RPC
  body (tool name + full argument object drive policy, caps, approval rules
  and the exact-action hash). Delegate per tool; discovery authorizes as
  `initialize`/`list`.
* **Discovery filtering is visibility** — `tools/list` answers only the
  tools the delegation allows; invoking a hidden tool's name directly is
  still independently authorized (and denied if out of scope). Hiding is
  never the control.
* **Claude.ai's remote connector needs a public HTTPS issuer** — it
  connects from Anthropic's infrastructure (`./oauth-tunnel.sh` for the
  demo; real domain for durable). Desktop-local connectors work on
  localhost.
* **Static-header credential (SDK path)** — the agent's MCP config carries
  the delegation token as a literal/env header with a TTL matching the
  delegation; refresh is a re-mint + config reload. The OAuth connector
  path (Claude/Inspector) refreshes itself via the rotating refresh grant.
* **Spend caps now work inside MCP bodies** — `params.arguments` feed
  `spend_per_order`/`max_count` (beyond the top-level body fields REST
  uses).

For the full worked demo — including the OpenClaw sandbox wiring (egress
delegation, supervisor credential, route probing) — see
[Demos.md §Demo 9](Demos.md) and [demo/mcp/README.md](../demo/mcp/README.md).
For protecting plain REST APIs the same way, see
[Protecting-Your-API.md](Protecting-Your-API.md).

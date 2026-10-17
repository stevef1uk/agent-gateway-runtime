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

## The four integration patterns

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

Two granularities, both working today:

| Enforcement level | What you get | How |
|---|---|---|
| Per **server** (day one) | every MCP session against that server is governed: delegation, scope, cap, audit, approval gate | gateway fronts the MCP server; JSON-RPC calls arrive as ordinary HTTP; the gateway derives tool=/mcp, action=POST |
| Per **tool** (roadmap) | each `tools/call` judged by its own `params.name` → tool-scoped policy | an MCP filter in the gateway parses the JSON-RPC body and re-derives resource/action per call (tracked as a roadmap adapter) |

For self-operated MCP servers there is a variant worth knowing: wrap the MCP
server with the gateway agent middleware (a thin server that requires the
delegation JWT before forwarding) if you prefer enforcement to live next to
the server rather than in front of it.

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

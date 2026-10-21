# The demo MCP server (`mcpsrv`)

A stand-in for a **customer's own MCP server** — deliberately a plain image
(no licence/encryption), exactly like [`demo/api/`](../api/README.md),
because it represents *your* service, not a vendor part.

It is an ordinary MCP server: streamable-HTTP at `/mcp` (stateless), a
health endpoint, standard `initialize` / `tools/list` / `tools/call` JSON-RPC
over the wire. There is nothing gateway-specific in it — any MCP client can
talk to it directly, which is precisely what Demo 9 Part A shows.

## Tools

| Tool | Purpose | Demo role |
|---|---|---|
| `add_customer` | writes a customer record (first/last/email/optional company) | the delegated action — the story's "Create Customer" |
| `lookup_customer` | reads by email, id (`CUST-0002` or `2`) or "First Last" | low-risk read, auto-allowed |
| `list_customers` | lists the CRM | low-risk read |
| `add`, `echo`, `get_info` | math / echo / server info (kept from the original demo MCP server) | plumbing |
| resource `config://server` | server status JSON | — |

Beyond the MCP surface, the CRM also exposes a plain REST **deletion**:
`DELETE /customers/{id}` removes the record (404 for an unknown id) and
returns it. That path exists so Demo 9 Part D can hold deletions for human
approval: the gateway derives `resource=/customers*`, `action=delete` from
the HTTP verb — a (resource, action) pair the delegation's `approval_rules`
can uniquely match, which the MCP endpoint (every call is `POST /mcp`) does
not expose per-tool today.

State is an **in-memory store seeded with two customers** (Ada Lovelace,
Grace Hopper); every container restart resets it. `mcp-demo.sh` restarts
`mcpsrv` at the start of a run for that reason.

## Proof-of-execution, out of band

`GET /customers` (plain REST, no auth) returns the whole CRM — the
MCP equivalent of demoapi's `executed_count`: the demo script curls it from
the host to prove what actually landed, independent of the agent's own
account of its work.

## Running it

The compose stack builds it from this directory on first `up`
(`agent-gateway-mcpsrv:1.0.0`; `MCPSRV_IMAGE` to override). Rebuild after
edits:

```bash
make image-mcp
cd demo && docker compose up -d mcpsrv
```

Try it raw (an ordinary MCP client view — no gateway in between):

```bash
curl -s http://localhost:8091/healthz
curl -s http://localhost:8091/customers
curl -s -X POST http://localhost:8091/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"lookup_customer","arguments":{"query":"ada@example.com"}}}'
```

## Why there is a second gateway instance

The gateway's `UPSTREAM_URL` (where it forwards allowed calls) is set per
*instance*. The primary gateway forwards `/orders`, `/api/*` to `demoapi`;
Demo 9 runs a second instance (`gateway-mcp`, published on host port 8085)
with `UPSTREAM_URL=http://mcpsrv:8091`, so MCP traffic gets its own policy
enforcement point without touching the other demos. Same decision pipeline:
identity → delegation → scope → audit, and instant revocation.

## Current enforcement granularity (worth saying out loud)

At the `/mcp` endpoint the gateway derives `resource=/mcp`,
`action=create` for every MCP tool call — **per-server** governance
(integration Pattern C). The MCP wire protocol is what the agent speaks;
the delegation scopes and audits the whole MCP surface. Identifying
`params.name` per `tools/call` (per-*tool* holds inside MCP bodies) is the
gateway product's next MCP adapter — this demo exists partly to motivate
it. Spend caps and per-call approval rules still work through the same
delegation machinery your REST demos use.

## Environment variables

- `MCP_HOST` (default `0.0.0.0`), `MCP_PORT` (default `8091`),
  `MCP_TRANSPORT` (`streamable-http` | `sse` | `stdio`)

## A note on the ZAP scan

`security/zap-scan.sh` includes `mcpsrv` (8091) and `gateway-mcp` (8085) in
its default target list; `make security-scan-mcp` scans just these two.
The reports land in `security/results/` alongside the rest.

## Using this for your own MCP server

The reusable recipe — dedicated gateway instance, the delegation JSON,
agent client config, the human-gated dangerous-operation pattern and
today's granularity limits — is
[docs/Protecting-Your-MCP.md](../../docs/Protecting-Your-MCP.md); the
worked demo is Demo 9 (`demo/mcp-demo.sh`, see
[docs/Demos.md](../../docs/Demos.md)).

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
| `find_customer` | fuzzy-find customers by substring over name/email/id/company | conversational demo finder |
| `delete_customer` | deletes a customer (MCP twin of the REST delete) | the per-tool approval demo — held by rule |
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

## Enforcement granularity (upgraded: per tool)

The gateway **parses the MCP JSON-RPC body** at the enforcement point: for
`tools/call` the action is the invoked **tool name** and the tool's full
argument object feeds spend caps, approval rules and the action hash;
`initialize` and `tools/list` authorize as `initialize` / `list`. The
delegation therefore scopes MCP *per tool* (`actions: ["initialize",
"list", "add_customer", …]`, `approval_rules` matching tool names) and the
audit trail carries which tool each call used. Discoverability is filtered
too: `tools/list` answers only the tools the delegation allows (visibility
only — calls are always re-authorized). Held/call outcomes reach MCP
clients as JSON-RPC envelopes (`isError` + structured `approval_required`
payload) so real clients (Claude, Inspector) render the hold correctly.
Approval remains single-use and bound to the exact action hash — arguments
changed after a hold cannot reuse it.

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

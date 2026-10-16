# demoapi — the demo *protected API*

`demoapi` is a stand-in for a **customer's own API** — the thing Agent Gateway
exists to protect. It is deliberately plain: no secure-packager encryption, no
licence token, no entrypoint ceremony, because unlike the authz/tokensvc/
gateway/console images it is **not vendor-delivered** — in a real deployment
this is *your* service.

## What it shows

The point of this component is to make the gateway's **two-phase execution**
observable: a high-risk action returns **202 + an approval record** and the
downstream must NOT have been called. When the human approves, the agent
retries the identical action and it executes **exactly once, single-use**.
That claim is normally invisible — here it is not: every response carries a
per-path call counter (`executed_count`, mirrored on the
`X-Demoapi-Call-Count` response header). If the counter says `1` after the
retry, the API genuinely ran once — and nothing after the held phase meant
the API never moved:

```
1st call  → 202 {"status":"approval_required","approval_id":"apr-…",
                 "reason":"sensitive API access requires a human"}
retry     → 200 {"status":"ok","executed_count":1,
                 "note":"executed BEHIND the Agent Gateway"}
```

`demoapi` also echoes the actor-delegation headers the gateway injects on
every allowed forward — `X-Auth-User`, `X-Auth-Agent`, `X-Delegation-ID`,
`X-Request-ID` — showing what a real downstream service sees so it can apply
its own secondary authz and log the actual actor.

## Wiring

The gateway forwards **allowed** calls to it via `UPSTREAM_URL`:

| Platform | Where set | Values |
|---|---|---|
| docker compose (local) | `demo/docker-compose.yml` → `gateway.environment` | `UPSTREAM_URL=http://demoapi:8090`, plus the `demoapi` container itself |
| k3s cluster | `k3s/agentgw.yaml` → `gateway.env` | `UPSTREAM_URL=http://demoapi:8090`, plus `demoapi` Deployment + Service (ClusterIP) |

Remove `UPSTREAM_URL` to restore the gateway's synthetic echo (no upstream
reached; useful for pure PEP tests).

## Requiring human approval *before* the API is callable

No gateway/UI change is needed — it is a **per-delegation approval rule**
set at delegation creation. The OPA policy evaluates
`input.delegation.approval_rules` and downgrades any matching call from
*allow* to *requires-approval*:

```json
POST /v1/delegations/          (authz service; needs a verified OIDC ID token)
{
  "id_token": "<the human's ID token>",
  "agent_id": "finance-agent-7",
  "resources": ["/orders", "/api/sensitive*"],
  "actions": ["read", "create"],
  "expires_in_seconds": 1800,
  "approval_rules": [
    { "when": { "resource_pattern": "/api/sensitive*" },
      "require": true,
      "rationale": "moving money always needs a human" }
  ]
}
```

Notes on the rule:

* `resource_pattern` / `action_pattern` use **exact, prefix (`pre*`) or
  suffix (`*suf`) matching** — a bare `*` is *not* a glob-all; to match any
  action **omit the value** (an empty pattern always matches).
* `rationale` is what the human sees in the 202 response and on the
  console/webhook — write it for the approver.
* Rules are **per-delegation**: the same gateway can serve delegations where
  `/api/sensitive` auto-runs (no rule) and delegations where it always
  requires a human — the human's grant decides.

Who may approve: the **admin-token holder** (`X-Admin-Token` =
`GATEWAY_ADMIN_TOKEN`, operator surfaces only — the agent runtime never has
it) **and** the `approver_id` must equal the delegating user the approval is
bound to (`APPROVAL_ENFORCE_APPROVER`); the console supplies the verified
session subject automatically. Everything is audited
(`audit_events.approver_id`).

## Build & run

* Image: `demo/api/Dockerfile` — a **standalone module** (own go.mod, no
  product dependencies; source lives in this directory next to the
  Dockerfile) — plain alpine, non-root, multi-arch, and it declares
  `ARG TARGETOS`/`ARG TARGETARCH`.
* Build from this directory (in the agent-gateway-demo repo):
  `cd demo/api && docker buildx build --platform linux/amd64,linux/arm64 \
     -t stevef1uk/agent-gateway-demoapi:1.0.1 -t stevef1uk/agent-gateway-demoapi:latest --push .`
* Locally (no docker): `go run .` then
  `curl -s -X POST localhost:8090/whatever` — watch `executed_count`.
* Full scripted walkthroughs: the compose demo and the k3s cluster both run
  this flow; see `../docker-compose.yml` and `../../k3s/agentgw.yaml`. One script drives both: ``demo/protected-api-demo.sh` (compose by default, `--node <ip>` for the k3s cluster; run from the repo root).

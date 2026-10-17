# Policy as code — OPA/Rego policies

*"The limits and approval rules are a useful start, but our guardrails are
real rules — about resources, amounts, teams, time of day. How do we write
them as code, review them in git, and change them without redeploying?"*

Agent Gateway ships two policy engines behind one contract:

| Engine | Selected by | What it is |
|---|---|---|
| **built-in** (default) | nothing to set | the table-driven rules the console edits: scope, spend cap, count limit, approval rules — implemented in Go (`BasicAuthorizer`) |
| **OPA** | `AUTHZ_POLICY_ENGINE=opa` | your policy as a Rego file, evaluated with `opa eval` per decision — full expressive power of Open Policy Agent |

Both answer the same question — *allow, hold for approval, or deny?* — with
the same decision object, so everything above them (gateway, console, audit,
approvals) is engine-agnostic. Delegation revocation and expiry are enforced
by the authz service **before** the policy runs; a Rego policy can never be
talked into allowing a revoked or expired delegation.

> **Which engine do you need?** The built-in engine enforces scope patterns,
> the spend cap and the count limit out of the box; anything beyond that —
> time windows, tenants, deny-lists, custom limits — needs OPA. The full
> split, with a worked example: [Protecting-Your-API.md](Protecting-Your-API.md).

## The decision contract

For every request the authz service builds this JSON input and evaluates
`data.authz.decision` against your policy:

```json
{
  "now": "2026-10-16T09:00:00Z",
  "delegation": {
    "id": "del-…", "user_id": "alice", "agent_id": "orders-bot",
    "resources": ["/orders"], "actions": ["read", "create"],
    "expires_at": "2026-10-16T10:00:00Z", "revoked_at": "",
    "created_at": "2026-10-16T08:55:00Z",
    "limits": {"spend_per_order": {"type": "currency", "max": 200, "unit": "EUR"}},
    "approval_rules": []
  },
  "action": {
    "agent_id": "orders-bot", "user_id": "alice",
    "resource": "/orders", "action": "create", "tenant": "",
    "context": {"amount": 250}
  },
  "limits":          { "…same map as delegation.limits, for convenience": {} },
  "approval_rules":  []
}
```

Your policy must produce one object:

```json
{"allow": true, "require_approval": true,
 "reason": "amount 250 exceeds auto-approve limit 200 EUR; approval required",
 "policy_id": "opa"}
```

The gateway maps it to HTTP:

| Decision | Gateway does |
|---|---|
| `allow` + `require_approval: false` | executes — forwards upstream, 200 |
| `allow` + `require_approval: true` | **holds** — returns 202 with an `approval_id`; a human approves, then the agent retries and gets 200 (single-use, bound to the exact action hash) |
| `allow: false` | refuses — 403 with your `reason` in the body and the audit trail |

`context` carries **seven** of the request body's keys — `amount`, `count`,
`recipient`, `to`, `resource`, `id`, `target` — this is where money and volume
rules read from. Any other body field is invisible to the policy (see
[Protecting-Your-API.md](Protecting-Your-API.md)). `limits` are keyed by the
limit's **name** (`spend_per_order`, `max_count`); the `type` field is a
human label (`currency`/`count`), `max`/`unit` do the arithmetic.

## Anatomy of the bundled policy

The default policy is a complete, working Rego v1 file shipped **in this
repository** at [`demo/policies/authorizer.rego`](../demo/policies/authorizer.rego)
(byte-identical to the copy baked into the image at
`/etc/agent-gateway/policies/authorizer.rego`; its 8-case test suite sits
beside it). It reproduces the built-in engine's semantics and is meant to be
read, copied and edited. It is five layers:

1. **Pattern matching** — `match()` implements the delegation's scope
   syntax: exact (`/orders`), prefix (`/orders/*`), suffix (`*/history`),
   and a bare `*` (**match-all**). The bare-`*` case mirrors
   `delegation.Match()` in the Go source exactly — the two engines must
   never disagree on a pattern (a divergence was caught by the egress demo:
   the OPA path ignored a bare-`*` approval rule and let a held action
   straight through; `match()` now carries the fix).
2. **Derived predicates** — `resource_allowed`, `action_allowed`,
   `agent_bound`, `user_bound`: does the request fit the delegation's scope
   and identity binding?
3. **Hard denials** — `deny_reasons`: each violation produces a precise
   reason (`resource not allowed: /payments`, `count 5 exceeds limit 3`, …).
   Count limits (`max_count`) deny; there is no middle ground for them.
4. **Approval upgrades** — two independent sources push
   `require_approval: true`:
   - **spend caps**: `context.amount` above `spend_per_order` does *not*
     deny — it downgrades to human approval (the console's cap setting
     lands here);
   - **approval rules** carried by the delegation: `require`,
     `when_resource_pattern`, `when_action_pattern`, `when_extra` (all
     listed context keys must match), `rationale` becomes the `reason`.
5. **The decision object** — assembled fail-closed: `default allow := false`,
   and a `default decision` of `{"allow": false, "reason": "no matching
   rule"}`. An incomplete policy denies, by construction.

The policy is ordinary Rego: anything goes — time-of-day windows
(`input.now`), tenant allow-lists, per-agent overrides, deny-lists,
escalation for dangerous actions.

## Enabling the OPA engine

```bash
AUTHZ_POLICY_ENGINE=opa                      # selects the OPA engine
OPA_POLICY_PATH=/etc/agent-gateway/policies/authorizer.rego   # optional; this is the default
```

Requirements, enforced at startup (the service refuses to start otherwise):

- the policy file exists and **compiles** — validation runs through
  `opa check` against OPA 1.x (Rego v1: policies written for OPA 0.x need
  `import rego.v1` / `if` keyword updates; OPA 1.x is what ships),
- the `opa` binary is on `PATH` (the authz image ships
  `opa 1.21.2-static` at `/usr/local/bin/opa`).

`OPA_POLICY_PATH` may point at a **directory** of `.rego` files — they are
loaded together, which lets you split policy per concern.

The demo stack ships a ready-made override that does exactly this — same
stack, Rego engine, the default policy from this repository:

```bash
cd demo
docker compose -f docker-compose.yml -f docker-compose.opa.yml up -d
```

Or set it once for the session so every later command (including `demo.sh`)
keeps the override:

```bash
export COMPOSE_FILE=docker-compose.yml:docker-compose.opa.yml
docker compose up -d          # and ./demo.sh run against the same stack
```

(`demo.sh` starts the stack with `--no-recreate`, so it never silently
reverts a running override back to the built-in engine.)

## Bringing your own policy

The shipped override ([`demo/docker-compose.opa.yml`](../demo/docker-compose.opa.yml))
already mounts the repository's policy over the bundled one and selects the
engine — copy it, or mount your own file the same way:

```yaml
# docker-compose.override.yml
services:
  authz:
    image: stevef1uk/agent-gateway-authz:latest
    environment:
      AUTHZ_POLICY_ENGINE: opa
      OPA_POLICY_PATH: /policy/authorizer.rego
    volumes:
      - ./policies/authorizer.rego:/policy/authorizer.rego:ro
```

```bash
docker compose -f docker-compose.yml -f docker-compose.override.yml up -d
```

Start from the default file (it is the full contract, ready to edit), change
one rule, reload, watch the decision change.

## Hot reload — safe by construction

The authz service polls the policy path every **5 seconds**. With the shipped
override that path is `demo/policies/authorizer.rego` on your host, so
editing that file with your normal editor is the whole workflow:

1. change detected → the candidate is compiled with `opa check`;
2. **valid** → it is *mirrored* into an internal serving directory and
   becomes the policy decisions evaluate;
3. **invalid** → the reload is rejected and logged
   (`opa policy reload REJECTED (previous policy still serving): …`) and the
   last good policy keeps answering decisions — your mistake cannot take the
   gateway down, and a half-written file is never evaluated;
4. fixing the file is picked up the same way, with no restart.

Decisions always read the validated mirror, never the live file — so the
"previous policy still serving" promise holds even between polls.

## The policy playground (`/policy.html`)

The same hot-reload loop, in the browser. With the override running, open
**http://localhost:8083/policy.html** — it reads the live file, lets you edit
and apply it, and runs decision probes (€150 / €250 / out-of-scope `/payments`)
against the **running** engine so you watch the reload take effect within five
seconds. A **Break it on purpose** button writes invalid Rego, shows the reload
being refused, and proves the previous policy keeps answering.

**Apply compiles first.** Pressing **Apply** hands your edit to the authz
service's `POST /v1/policy/validate`, which runs the same `opa check` the
hot-reloader uses, and the page shows the verdict immediately — a valid edit is
written and swapped in within seconds, an edit that does not compile is called
out with the exact compiler diagnostic (file, line, and message) instead of
appearing to do nothing. Either way the last good policy keeps serving until a
valid replacement is ready.

The three probes should read, on the default policy:

| Probe | Decision |
| --- | --- |
| €150 · `/orders` | `ALLOW` |
| €250 · `/orders` | `ALLOW · approval required` (amount 250 exceeds auto-approve limit 200 EUR) |
| €50 · `/payments` | `DENY` (resource not allowed: /payments) |

Edit the `spend_breached` rule — the auto-approve cap — changing
`num(input.action.context.amount) > num(l.max)` to
`num(input.action.context.amount) > 500`; **Apply**, and the €250 probe flips to
`ALLOW` within ~5 s. Replace only the right-hand side — a stray token that does
not compile is refused, and **Apply** shows you the exact compiler error.

**Keeping the editor honest:** the page polls the file every three seconds. If
it changes on disk — your own editor, or a `git restore` — the editor refreshes
to match (and says so); if you have unsaved edits it warns instead of clobbering
them. **Reload from file** forces a fresh read on demand.

**Resetting a mess-up:** the initial policy is a known-good file tracked in
this repository (`demo/policies/authorizer.rego`), and the web image ships a
pristine copy of exactly it, so the page's **Restore initial policy** button
works even after the live file has been wrecked or you have opened the page in
a fresh browser session. The host-side equivalent is plain git:

```bash
git restore demo/policies/authorizer.rego   # back to the committed version
```

The button and git therefore converge on the same bytes — there is no hidden
state to recover from.

## Testing your policy

Unit tests are plain Rego tests (the default suite: 8 cases covering scope,
bindings, caps, approval rules, fail-closed defaults):

```bash
opa test demo/policies/        # the default policy shipped in this repository
```

A single decision, without any stack running — feed the input document from
the contract above and ask for `data.authz.decision`:

```bash
opa eval --stdin-input -d demo/policies/authorizer.rego 'data.authz.decision' < input.json
# → {"allow": true, "require_approval": true, "reason": "amount 250 exceeds …", "policy_id": "opa"}
```

Suggested loop while authoring: `opa test` in CI, `opa eval` for the
one-off's, then run [Demos.md](Demos.md) (or `demo/demo.sh`) end-to-end —
the scripted walkthrough passes on both engines, so it doubles as a
regression test for your policy.

## Recipes

```rego
# business hours only (input.now is RFC3339)
deny_reasons contains "orders outside 09:00–17:00 CET" if {
    t := time.parse_ns("2006-01-02T15:04:05Z07:00", input.now)
    hour := time.clock(t)[0]
    hour < 9; hour >= 17
}

# anything addressed to the treasury always needs a human, whatever the amount
require_approval if {
    input.action.context.recipient == "treasury@acme.com"
}

# new tool namespaces are denied until explicitly scoped in
deny_reasons contains sprintf("resource not in approved catalogue: %s", [input.action.resource]) if {
    startswith(input.action.resource, "/tools/")
    not startswith(input.action.resource, "/tools/approved-")
}
```

(Keep denials in `deny_reasons` and upgrades in `require_approval` and the
decision object keeps assembling itself — that is the whole convention.)

## Operational notes

- **CLI, not a server.** Each decision shells out to `opa eval` with a 5s
  timeout; no OPA HTTP server, bundles or network policy store to run —
  the policy is a file, versionable next to your compose files.
- **Fail-closed everywhere.** Missing/invalid policy refuses service at
  start; runtime errors evaluate to `allow: false` with the error as the
  `reason`.
- **Auditable.** Decisions carry `policy_id: "opa"`, so audit trails show
  which engine decided what; denial reasons surface verbatim in the API
  403 body, the console and the audit feed.
- The demo stack runs the built-in engine by default; enabling the override
  above switches the identical flow onto OPA.

## Where to go next

- [Protecting-Your-API.md](Protecting-Your-API.md) — the catalogue of constraints: what the built-in engine enforces directly and what needs OPA
- [Architecture.md](Architecture.md) — the authorization loop these decisions sit in
- [Demos.md](Demos.md) — watch allow/hold/approve/deny play out live
- [Deployment-Guide.md](Deployment-Guide.md) — env vars and mounts in a production deployment
- [Security-and-Licensing.md](Security-and-Licensing.md) — what ships encrypted and what you control

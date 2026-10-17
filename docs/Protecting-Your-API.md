# Protecting your own API — a hands-on guide

*"I have an API. I want an agent to use some of it, with limits, and a human
in the loop for the sharp edges. What can I actually restrict, and where do I
set it?"*

This is the practical companion to the other two policy documents:

- [Integration-Patterns.md](Integration-Patterns.md) — **how** to put the
  gateway in front of an API (reverse proxy, SDK sidecar, MCP front-door).
- [Policy-and-OPA.md](Policy-and-OPA.md) — the **reference** for the OPA/Rego
  engine: the decision contract, the bundled policy, hot reload, the playground.

This document is the missing middle: a catalogue of **every constraint you can
configure**, split by *where* you configure it (the delegation record vs the
engine), what each one does to a request, and — just as important — **what the
built-in engine cannot do**, with the OPA recipe that covers the gap.

---

## 1. The 30-second model

Put the gateway between the agent and your API by pointing it at your upstream:

```yaml
gateway:
  environment:
    - UPSTREAM_URL=http://your-api:8090
```

Every request the agent makes then runs through the same loop:

```
agent ──▶ gateway ──▶ authz (decide) ──▶ allow / hold / deny
                │
                └──▶ your API (only on allow)
```

Before deciding, the gateway turns the raw HTTP request into a
**resource / action / context** triple. You don't have to change your API for
this to work — but knowing the mapping is how you write rules that actually
match.

| What | Default derivation | Override header |
|---|---|---|
| **resource** | the request path, e.g. `/suppliers/42/orders` | `X-Agent-Resource` |
| **action** | the HTTP method, mapped: `GET`/`HEAD`→`read`, `POST`→`create`, `PUT`/`PATCH`→`update`, `DELETE`→`delete` | `X-Agent-Action` |
| **tool** (audit label) | first path segment | `X-Agent-Tool` |
| **context** | these JSON body keys only: `amount`, `count`, `recipient`, `to`, `resource`, `id`, `target` | — (see §5) |

The decision maps to HTTP like this:

| Decision | Gateway does |
|---|---|
| `allow` (no approval) | forwards to your API → **200** |
| `allow` + `require_approval` | **holds** → **202** + `approval_id`; a human approves, agent retries → **200** |
| `allow: false` | refuses → **403** with the reason in the body |

> **The one thing to internalise:** the delegation is the unit of authority.
> A request is allowed only if it matches the *user→agent delegation* **and**
> the engine agrees. You grant authority when you create a delegation; the
> engine only ever *narrows* it.

---

## 2. The full list of knobs

Set these on the **delegation** (per user, per agent). "Where" tells you which
surface exposes each one today.

| Knob | Delegation field | Effect | Direct (console) | Direct (API) | OPA |
|---|---|---|---|:---:|:---:|:---:|
| Who the agent is | `agent_id` | agent must match | ✅ | ✅ | (pre-checked) |
| Who delegated | `user_id` | bound to the verified user | ✅ (sign-in) | ✅ (id_token) | (pre-checked) |
| Which resources | `resources[]` | scope patterns the path must match | ✅ | ✅ | ✅ |
| Which actions | `actions[]` | `read`/`create`/`update`/`delete` | ✅ | ✅ | ✅ |
| Expiry | `expires_in_seconds` | delegation dies at T | ✅ | ✅ | (pre-checked) |
| Agent→agent depth | `max_depth` | how many sub-delegations remain | ✅ | ✅ | — |
| Per-order spend cap | `limits.spend_per_order` | amount **above** cap → hold for approval | ✅ | ✅ | ✅ |
| Hard count limit | `limits.max_count` | count **above** cap → deny | ❌ | ✅ | ✅ |
| Any other limit name | `limits.<name>` | **not enforced by the built-in engine** | ❌ | ✅ | ✅ |
| Approval rules | `approval_rules[]` | force a human hold on a match | ❌ | ✅ | ✅ |
| Revocation | `DELETE /v1/delegations/{id}` | kills the delegation immediately | ✅ (console) | ✅ | (pre-checked) |
| Scopes | `scopes[]` | carried for token/OAuth metadata | ❌ | ✅ | — |

Legend: ✅ works there · ❌ not exposed · (pre-checked) enforced before the
engine runs and cannot be overridden by policy.

Two design points worth stressing:

- **Revocation and expiry are not policy.** They are enforced by the authz
  service *before* any engine runs, so no Rego file (and no bug in one) can
  resurrect a revoked or expired delegation.
- **Hold vs deny is deliberate.** Spend caps *downgrade* an allow to
  "ask a human"; count limits *deny*. Use a cap when a person's judgement is
  the right answer, a limit when it is not.

---

## 3. Scope patterns and actions

`resources[]` and `actions[]` are lists of patterns. Matching supports four
forms:

| Pattern | Matches | Example |
|---|---|---|
| `/orders` | exactly `/orders` | one endpoint |
| `/suppliers/*` | any path with that prefix | `/suppliers/42/orders` |
| `*/history` | any path with that suffix | `/orders/7/history` |
| `*` | **everything** (built-in engine) | *avoid — too broad* |

> **Caveat — the bare `*` differs between engines.** The built-in engine treats
> `*` as "match all"; the bundled Rego policy deliberately treats a bare `*`
> as *non-matching* ("scope must name something"). Prefer explicit patterns
> like `/refunds/*` so behaviour is identical on both engines.

Actions use the same syntax, but in practice you list the CRUD verbs the
agent may use (`read`, `create`, `update`, `delete`). Because the default
mapping derives the action from the HTTP method, a delegation with
`["read", "create"]` lets the agent `GET` and `POST` but blocks `PUT` and
`DELETE` — without any code change in your API.

---

## 4. The two limits the built-in engine enforces

The delegation's `limits` is a map keyed by limit **name**. The built-in
engine reads exactly two names:

```json
{
  "limits": {
    "spend_per_order": { "type": "currency", "max": 200, "unit": "EUR" },
    "max_count":       { "type": "count",    "max": 3 }
  }
}
```

- **`spend_per_order`** reads `context.amount`. If it is **greater than**
  `max`, the decision becomes *allow + require_approval* (a human hold), with a
  reason like `amount 250 exceeds auto-approve limit 200 EUR; approval required`.
- **`max_count`** reads `context.count`. If it is **greater than** `max`, the
  decision is a hard **deny** (`count 5 exceeds limit 3`).

Everything else in `limits` is stored and passed to the engine, but the
**built-in engine ignores it**. The `type` field (`count`/`currency`/`bytes`/
`duration`) is a human label — only the map **key** is acted on. To enforce
`bytes`, `duration`, or your own limit names you write it in OPA (§6).

> **The `amount`/`count` must be in the JSON body** under those exact keys for
> the built-in caps to see them. A custom API that puts the amount somewhere
> else needs the agent to add `"amount": …` to the request body, or a Rego
> rule that reads whatever the context *does* carry (§5).

---

## 5. Approval rules — and the context limitation

An approval rule forces a human hold when it matches, independent of amounts:

```json
{
  "approval_rules": [
    {
      "when": { "resource_pattern": "/refunds/*", "action_pattern": "create" },
      "require": true,
      "rationale": "refunds always need a human sign-off"
    }
  ]
}
```

- `resource_pattern` / `action_pattern` — same pattern syntax as §3 (empty =
  match anything).
- `extra` — a map of `context-key: value` that must **all** match, e.g.
  `{ "recipient": "treasury@acme.com" }`. Matching is **exact string equality**.
- `require: true` turns the match into an approval hold; `rationale` becomes
  the reason the approver sees.

### ⚠ No body context except seven keys

This is the single most surprising limitation, so it gets its own warning.
The gateway builds `context` from **only these seven body keys**:

```
amount · count · recipient · to · resource · id · target
```

Anything else in the request body (a `description`, a `category`, a nested
object) is **not** visible to the built-in engine or to Rego. So:

- an `extra` match on `description` silently never fires;
- a Rego rule reading `input.action.context.description` silently never fires.

If your policy needs to key on some other field, either (a) have the agent
send it under one of the seven keys, or (b) extend `deriveAction` in the
gateway (`internal/gateway/server.go`) to copy it through.

---

## 6. What the built-in engine cannot do — and the OPA fix

Everything below is out of reach of the table-driven engine. Switch the authz
service to the OPA engine (`AUTHZ_POLICY_ENGINE=opa` + `OPA_POLICY_PATH=…`, see
[Policy-and-OPA.md](Policy-and-OPA.md)) and write the rule in Rego.

| You want… | Built-in | OPA recipe |
|---|---|---|
| Enforce `bytes`/`duration`/custom limits | ❌ | `deny_reasons contains … if { … }` on `input.action.context` |
| Time-of-day / business-hours window | ❌ | read `input.now` |
| Tenant rules | ❌ — the gateway never populates `tenant` today | read `input.action.tenant` (only set by a direct `/v1/check` call) |
| Deny-list / approved-catalogue of resources | ❌ | `startswith(input.action.resource, "/tools/")` |
| Per-agent overrides, multi-condition combos | ❌ | any Rego predicate |
| Composite approval (this recipient **and** this amount) | ⚠ extra is equality-only | `require_approval if { … }` |
| Running totals / aggregates across calls | ❌ (stateless per call) | needs state outside the policy — see note |

A few concrete recipes (Rego v1, drop into the bundled policy):

```rego
# Only allow the refunds tool during EU business hours.
deny_reasons contains "refunds outside 08:00–18:00 UTC" if {
    startswith(input.action.resource, "/refunds/")
    hour := time.clock(time.parse_ns("2006-01-02T15:04:05Z07:00", input.now))[0]
    hour < 8
}
deny_reasons contains "refunds outside 08:00–18:00 UTC" if {
    startswith(input.action.resource, "/refunds/")
    hour := time.clock(time.parse_ns("2006-01-02T15:04:05Z07:00", input.now))[0]
    hour >= 18
}

# Anything addressed to the treasury endpoint needs a human, any amount.
require_approval if {
    input.action.context.recipient == "treasury@acme.com"
}

# Deny any tool namespace that is not on the approved list.
deny_reasons contains sprintf("resource not in approved catalogue: %s", [input.action.resource]) if {
    startswith(input.action.resource, "/tools/")
    not startswith(input.action.resource, "/tools/approved-")
}
```

> **Aggregates are a different problem.** Rego here decides one request at a
> time with no cross-request memory; "no more than €1000 per agent per day"
> has to count somewhere. Keep that counter in your API (or a small sidecar)
> and either enforce it there or have this policy read a per-request `context`
> value your gateway injects.

---

## 7. Worked example — protect a Refunds API

Say your finance API exposes `POST /refunds` and `GET /refunds/{id}`, and you
want a support agent to issue small refunds, with anything big or to the
treasury held for a person.

### 7.1 Point the gateway at it

```yaml
services:
  gateway:
    environment:
      - UPSTREAM_URL=http://finance-api:8090
```

### 7.2 Create the delegation

The console (**http://localhost:8083**) is the quickest path: fill in Agent ID,
Expires, Resources `/refunds/*`, Actions `read, create`, and the Spend
limit/order. That covers the everyday case.

For the parts the console does not expose — the hard count limit and the
approval rule — use the API. The full payload:

```json
{
  "user_id": "alice",
  "agent_id": "support-bot",
  "resources": ["/refunds/*"],
  "actions": ["read", "create"],
  "expires_in_seconds": 3600,
  "limits": {
    "spend_per_order": { "type": "currency", "max": 100, "unit": "EUR" },
    "max_count":       { "type": "count",    "max": 3 }
  },
  "approval_rules": [
    { "when": { "resource_pattern": "/refunds/*", "action_pattern": "create",
                "extra": { "recipient": "treasury@acme.com" } },
      "require": true, "rationale": "treasury refunds need finance sign-off" }
  ]
}
```

```bash
curl -sS -X POST http://localhost:8081/v1/delegations/ \
  -H 'Content-Type: application/json' \
  -d @delegation.json
```

> **OIDC.** When the authz service has `OIDC_ISSUER_URL` set (the demo does),
> creation requires a verified user: add `"id_token": "<the user's OIDC ID
> token>"` to the body — the console's "Sign in with Dex" obtains it for you.
> When OIDC is not configured (dev only), the client-asserted `user_id` is
> trusted as-is. The response returns the delegation, an access token, and a
> one-time `agent_secret` to hand to the agent.

### 7.3 What each call now does

| Agent request | Decision |
|---|---|
| `GET /refunds/42` | **allow** → 200 |
| `POST /refunds` body `{"amount":50,"recipient":"cust@x.com"}` | **allow** → 200 |
| `POST /refunds` body `{"amount":250,"recipient":"cust@x.com"}` | **hold** → 202 (`amount 250 exceeds auto-approve limit 100 EUR`) |
| `POST /refunds` body `{"amount":50,"recipient":"treasury@acme.com"}` | **hold** → 202 (approval rule) |
| `POST /refunds` body `{"amount":50,"count":5}` | **deny** → 403 (`count 5 exceeds limit 3`) |
| `DELETE /refunds/42` | **deny** → 403 (`action not allowed: delete`) |
| `GET /payments/9` | **deny** → 403 (`resource not allowed: /payments/9`) |

### 7.4 Probe a decision without the gateway

The authz service exposes `/v1/check` directly, which is a fast way to test a
rule (no token, no upstream, no audit record):

```bash
curl -sS -X POST http://localhost:8081/v1/check \
  -H 'Content-Type: application/json' \
  -d '{"delegation_id":"del-…","resource":"/refunds","action":"create",
       "context":{"amount":250}}'
# {"allow":true,"reason":"amount 250 exceeds auto-approve limit 100 EUR; approval required",
#  "require_approval":true,"policy_id":"basic", …}
```

`policy_id` tells you **which engine answered** — `basic` or `opa` — which is
the quickest check that your OPA override is actually live.

---

## 8. Testing your rules

| Layer | How |
|---|---|
| Built-in rules | `POST /v1/check` (above) — assert `allow` / `require_approval` per case |
| Rego rules | `opa test demo/policies/` (unit) and `opa eval … 'data.authz.decision' < input.json` (one-off) |
| Whole flow | `./demo.sh` / [Demos.md](Demos.md) — passes on both engines, so it doubles as a regression test |
| Live editing | the [policy playground](Policy-and-OPA.md#the-policy-playground-policyhtml) at `http://localhost:8083/policy.html` |

---

## 9. Cheat sheet

| I want to… | Set |
|---|---|
| Let an agent read one endpoint | `resources:["/orders"], actions:["read"]` |
| Let it read a whole subtree | `resources:["/suppliers/*"]` |
| Cut off all writes | `actions:["read"]` |
| Expire access automatically | `expires_in_seconds: 900` |
| Kill access now | `DELETE /v1/delegations/{id}` |
| Auto-approve small orders, hold big ones | `limits.spend_per_order` |
| Hard-stop volume abuse | `limits.max_count` |
| Human sign-off on a resource or recipient | `approval_rules[]` |
| Limit agent→agent chaining | `max_depth` |
| Time windows, tenants, deny-lists, custom limits | OPA ([Policy-and-OPA.md](Policy-and-OPA.md)) |

## Where to go next

- [Integration-Patterns.md](Integration-Patterns.md) — insert the gateway in front of your API
- [Policy-and-OPA.md](Policy-and-OPA.md) — the Rego engine, contract, recipes, playground
- [Demos.md](Demos.md) — watch allow / hold / approve / deny play out live
- [Deployment-Guide.md](Deployment-Guide.md) — env vars and mounts for a real deployment

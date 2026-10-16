# Architecture

Agent Gateway is four stateless services plus two data stores. The design
separates **decision** from **enforcement** and treats the human as a first
class participant in the authorization loop.

## Services

| Service | Role | State |
|---|---|---|
| `authz` (:8081) | **Decision point.** Owns delegations and the policy engine. Verifies the human's OIDC ID token at delegation creation, binds the delegation to the verified subject, issues agent tokens, answers "is this action allowed?" from the PEP. | delegations (+ decision cache in Redis) |
| `gateway` (:8080) | **Policy enforcement point (PEP).** Sits in front of the tools. Resolves the caller's principal (JWT bearer or SPIFFE SVID), asks authz for a decision, gates approvals, forwards allowed calls to `UPSTREAM_URL`, writes audit events. | approvals store + audit sink |
| `tokensvc` (:8082) | Mints short-lived, delegation-scoped JWTs. Refuses to mint for expired or revoked delegations; embeds `jti` for instant revocation. | none |
| `web` (:8083) | Admin console + guided demo. Thin proxy over authz/gateway; never a second source of truth. | none |
| `postgres` | Durable store: `delegations`, `approvals`, `audit_events` (JSONB-first, indexed on the fields the services query). Schema auto-migrates on startup. | — |
| `redis` | jti revocation list + decision cache. | — |

## The authorization loop

```
1  Human (SSO) ──► POST /v1/delegations  (agent, resource, actions, limits,
                                          cap, expiry, id_token)
2  authz verifies the ID token against the OIDC provider (JWKS),
   binds delegation.user_id = token.subject (client-asserted names can only
   agree with it, never override it)
3  Agent ──► POST /token {delegation_id}
   tokensvc refuses revoked/expired delegations; JWT ~= 5 min, embeds jti
4  Agent ──► any tool call on the gateway, Bearer <jwt>
5  gateway resolves principal (JWT w/ revocation check, or SPIFFE SVID)
6  gateway ──► authz /decision  {principal, delegation, action}
7  Policy: resources ⊆ scope, actions ⊆ scope, transaction limits,
   approval rules → ALLOW | REQUIRE-APPROVAL | DENY
8a ALLOW      → forward to UPSTREAM_URL, audit allow
8b HOLD (202) → approval created, bound to (delegation, action_hash),
                NOT executed; the approval is single-use
8b' notification → gateway pushes an approval.required webhook
                (HMAC-signed) to operator automation — n8n / Slack /
                Teams / PagerDuty — so the human learns without
                watching the console; the console also shows a pending
                badge + toast on its approval poll
8c DENY       → refuse in place, audited; nothing forwarded
9  Human decides the pending approval (console, or Approve/Deny from
   the notification card via the operator API); a retry with the
   approved binding executes exactly once
10 Revoke: delegation revoked_at set → decisions deny instantly (authz) and
   even still-valid JWTs are refused at the gateway (redis jti check)
```

## Policy model

Current `authz` policy (a Rego/OPA authorizer is available as an alternative
engine in the codebase):

- **Resource/action scoping** — the delegation's resource patterns and action
  list are the outer boundary. Everything outside is denied outright.
- **Spend caps with downgrade** — `limits.spend_per_order{max,unit}`: action
  context `amount` above the cap **downgrades allow → "requires approval"**
  rather than denying, so valuable-but-legitimate work is possible with one
  human step. Below the cap it flows through automatically.
- **Count limits** — `max_count` over action `count` denies outright.
- **Approval rules** — declarative "require approval when <condition>" rules
  with an optional rationale, per delegation.

## Security properties

1. **Human identity is verified, not asserted.** Delegations can only bind to
   the OIDC token's subject; a claim in the request body can never create
   rights for somebody else.
2. **Scope is least-privilege and short-lived.** Delegations expire; agent
   tokens are 5 minutes by default and scoped to one delegation only.
3. **High-value actions are two-phase.** The upstream tool is never called
   until the specific action has a fresh, single-use human approval — and the
   human is *told*: the gateway pushes an HMAC-signed `approval.required`
   webhook to operator automation (Slack/Teams/n8n/PagerDuty — setup and
   receiver recipes in [Notifications.md](Notifications.md)), and the console
   surfaces a pending badge + toast, so nobody has to poll by hand.
4. **Revocation beats token validity.** The gateway consults the Redis jti
   list on every call: revocation takes effect immediately even for tokens
   that would pass cryptographic validation for minutes more.
5. **Audit completeness.** Every decision (allow / hold / deny) carries
   acting user, agent id, delegation id, tool/resource/action, policy id,
   approval id and approver — the row in `audit_events` is the record.
6. **Encrypted, licence-gated delivery.** Containers ship encrypted payloads;
   they start only with the customer's private key and a valid, vendor-signed
   licence token — [details](Security-and-Licensing.md).

## Trust boundaries

```
┌──────────────────────── browser ─────────────────────────┐
│ human signs in via OIDC; web relays tokens;              │
│ web never verifies them (authz does) ── the web tier     │
│ being compromised cannot mint rights for someone else;   │
│ secrets live in cookies only to power forms in dev       │
└───────────────────────────────────────────────────────────┘
┌─ agents ──► gateway: nothing crosses without a delegation ─┐
│ gateway ──► authz: every decision over the wire            │
│ gateway ──► upstream: only forwarded when ALLOW            │
└────────────────────────────────────────────────────────────┘
```

The web tier is deliberately thin: it relays ID tokens and approval decisions
but cryptographic verification lives only in `authz`, so there is exactly one
place that must trust the IdP.

## Scaling & HA

All four services are stateless when `PERSISTENCE=postgres` (state in
Postgres/Redis), so HA = more replicas behind a load balancer, a managed
Postgres, and managed Redis. No sticky sessions are needed — the OIDC flow is
cookie-based state that any replica can validate. See
[Deployment-Guide.md](Deployment-Guide.md) §6 for the full runbook.

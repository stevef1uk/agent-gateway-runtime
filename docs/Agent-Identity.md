# How agents get identified

*"These days an agent is anything that can call an LLM in a loop — frameworks
generate them constantly. How does the human know what's out there, and what
stops a rogue agent impersonating one?"*

The short answer: **the name is never the identity — the credential is.**
Agent Gateway does not try to identify agents by their framework names; it
*admits* them once through a human decision, then recognises them forever by
what they hold.

## The provision ceremony: registration = delegation

There is no agent registry, no "create agent account" step, and no anonymous
path in. An agent exists to the system only after a **verified human** (SSO)
creates a delegation naming it:

```
your framework/platform creates an agent as usual (any runtime, any language)
        │
        ▼ the delegating human opens the console (or calls the API)
   POST /v1/delegations
   { agent_id: "crm-ops-agent-7f3a",        ← the census key, human-chosen
     resources: ["/orders"], actions: ["read","create"],
     limits: {spend_per_order: {max: 200, unit: "EUR"}},
     id_token: <their SSO ID token> }       ← the human, cryptographically verified
        │
        ▼ authz verifies the ID token against the IdP, binds the delegation
          to the human's subject, and returns a ONE-TIME agent secret
        │
        ▼ the human delivers that credential to the agent process in a
          controlled channel (env var, secret store, provisioning API)
```

This act answers both puzzling questions at once:

1. **"How does the human know what's out there?"** — The console/audit trail
   is the *census*: every agent that ever received rights appears with its
   name, its delegating human, its scope, its expiry, and its complete action
   history. An unknown agent has no rights, because delegation is the only
   entrance.
2. **"What stops a rogue agent claiming an existing agent's name?"** — The
   name is free; the credential is not (next section).

## What the agent holds — the three layers

| Layer | What the agent must hold | What stops impersonation |
|---|---|---|
| **1. Delegation-scoped token** (default) | A short-lived JWT (~5 min) mintable only for its live delegation | Powers of the token are exactly the delegation (paths, actions, cap); revocation kills it instantly; audit records it. Ships **from image release 1.0.1 (authz/tokensvc):** minting additionally requires the **agent secret** issued at delegation time — knowing the delegation id is *not* identity |
| **2. Agent secret** (built in) | A 43-character, per-delegation credential delivered at creation | A rogue with the name — even the delegation id, even a leaked log line — cannot mint. The delegation stores only the SHA-256 digest of the secret; authz compares in constant time |
| **3. Workload identity** (SPIFFE/optional) | A platform-issued X.509 SVID presented *in the TLS handshake* | Cryptographic admission at the transport layer: a rogue process cannot present `spiffe://corp/ns/prod/agent/purchasing-agent-42`; the delegation binds to that verified identity too |

```json
{ "agent_id":      "crm-ops-agent-7f3a",
  "sub":           "Cg0wL…",              // the verifying human's OIDC subject
  "delegation_id": "del-…",
  "aud": "agent-gateway", "jti": "…" }    // the revocation handle
```

The mental model:

```
Framework name      → for humans; decoration; never trusted at runtime
agent_id            → the human-chosen census key fixed at admission time
Credential          → the true identity:
            today:   delegation-scoped JWT + agent secret (5 min, revocable)
            at scale: platform-issued workload identity (SPIFFE)
Keeping the triple (framework name ↔ agent_id ↔ credential) consistent
is one ceremony for admission; everything after is enforcement and audit.
```

## Scaling & Multiple Instances: Shared vs. Per-Instance Delegations

When deploying multiple instances, replicas, or worker processes of an agent, teams face a fundamental design choice: **should all instances share one delegation, or should each instance receive its own?**

### What happens if multiple instances share ONE delegation?

Technically, the gateway permits multiple instances to use the same `delegation_id` and `agent_secret`. Both will mint valid tokens and execute authorized tools. However, sharing delegations introduces significant operational risks:

| Dimension | Behavior When Sharing a Delegation | Operational Impact |
| :--- | :--- | :--- |
| **Authentication** | All instances mint valid short-lived JWTs from `tokensvc`. | Gateway accepts traffic from all instances. |
| **Audit Trail** | All instances record the exact same `agent_id` and `delegation_id`. | **Loss of attribution**: In `audit_events`, you cannot distinguish which container, pod, or worker process made which tool call. |
| **Spend Caps & Quotas** | Spend limits and rate limits apply to the shared delegation. | If a delegation has a cap of €500, Instance A can exhaust the entire budget, starving Instance B. |
| **Revocation & Blast Radius** | Revocation is all-or-nothing at the delegation level. | If Instance A is compromised or enters an uncontrolled loop, revoking the delegation **terminates Instance B as well**. |

---

### The Recommended Pattern: Per-Instance Delegations

For persistent or long-running worker replicas, provision a distinct delegation per instance using instance-specific suffixes:

```text
sales-crm-worker-pod1-7f3a  → Delegation del-sales-01  → Agent Secret sec-xxx
sales-crm-worker-pod2-8b4c  → Delegation del-sales-02  → Agent Secret sec-yyy
```

**Benefits of per-instance delegations:**
1. **Pinpoint Auditability**: In incident response or compliance reviews, every audit log entry isolates the exact container or pod that took action.
2. **Targeted Revocation**: If a specific replica behaves anomalously, an operator revokes only that replica's delegation in the console. The compromised instance is halted within seconds; all other replicas continue serving traffic unaffected.
3. **Partitioned Budgets**: Spend caps and approval rules apply individually per worker rather than depleting a shared pool.

---

### How to Handle Ephemeral Agent Fleets at Scale

When orchestrators (Kubernetes, Celery, Temporal) dynamically spin up dozens or hundreds of short-lived agent instances, human operators cannot manually click "Create Delegation" in the console for each one. The architecture provides two automated patterns:

1. **Platform Onboarding Broker (API-Driven)**:
   - When the orchestrator schedules an agent pod, a privileged provisioning service calls `POST /v1/delegations` programmatically on behalf of the sponsoring human principal.
   - The returned `agent_secret` is delivered directly into the container's environment or mounted secret store.
2. **Workload Identity (SPIFFE / mTLS & Pattern Binding)**:
   - Ephemeral workloads receive cryptographic identities at the transport layer (e.g. `spiffe://corp/ns/prod/agent/worker-*`).
   - The gateway validates the SVID during the TLS handshake and binds the agent fleet to a class delegation pattern automatically without managing individual static secrets.

---

## Recommendations when agents multiply

- **Name each agent per-instance**, self-describing and team-prefixed:
  `plf-env-agent-id` (ex. `sales-crm-researcher-7f3a`, `jenkins-prod-deployer`).
  One delegation per agent process. The audit `agent_id` column then always
  pinpoints exactly one workload.
- **Trust the distribution channel for the secret** the way you trust it for
  an API key: provisioning scripts, secret stores, console copy, never
  chat transcripts or logs. Both the delegation id and the agent secret are
  credentials.
- **Scale with platform identity**, when fleets grow into dozens of agent
  runtimes: SPIFFE/SPIRE issues SVIDs to workloads automatically; built-
  admit pattern-bind matching (`spiffe://corp/ns/prod/agent/*`) is on the
  roadmap — see [Deployment-Guide.md](Deployment-Guide.md) §7.3 SPIFFE.

## FAQ corner

**Can two agents share a delegation?** Technically a token is scoped to one
delegation, so if both share the secret they act indistinguishably. Avoid it:
identity is enforced only when the audit trail can tell agents apart.

**What if the agent secret leaks?**
Revoke the delegation — minting stops immediately and outstanding tokens die
within seconds at the gateway; the leak's damage is bounded by the
delegation's scope and expiry, not by your infrastructure.

**Where is this shown?**
The [graphical demo](../README.md#demo-2---graphical) exercises all three
live: SSO-bound delegation → the credential gate (a name without a
credential is refused) → instant revocation despite a still-valid token.

# Running the demos

The demos run against the same seven-container stack in [`demo/`](../demo/)
and make **real** calls — nothing is simulated. Run the stack first:

```bash
cd demo
docker compose up -d        # pulls published images from Docker Hub
./demo.sh
```

| Endpoint | Status |
|---|---|
| http://localhost:8083 | admin console |
| http://localhost:8083/demo.html | graphical guided demo |
| http://localhost:8083/policy.html | OPA policy playground *(needs the policy override — see Demo 3)* |
| http://localhost:8080 | gateway (PEP) — what your agents call |
| http://localhost:8081, :8082, :5556 | authz · tokensvc · SSO (Dex) |

## Demo 1 — scripted (`demo/demo.sh`)

A terminal walkthrough of the complete story, with an explanation at every
step. It performs live: SSO sign-in via the OIDC redirect chain, delegation
creation bound to the verified subject, agent token minting, then the money
loop:

| Step | What happens | Expected |
|---|---|---|
| 5 | agent orders €150 (≤ €200 cap) | **HTTP 200** — auto-allowed, no human |
| 6 | agent orders €250 (> €200 cap) | **HTTP 202 + approval_id** — held, nothing executed |
| 7 | you approve the pending action | approval recorded, single-use |
| 8 | agent retries the exact €250 action | **HTTP 200** — executes once |
| 9 | delegation revoked, agent retries | **HTTP 403** — token still valid, still denied |

The two properties worth calling out to an audience:

1. **The money never moved without a human** for the high-value action — the
   upstream call was not made; the hold is not a status code, it is a real
   gate.
2. **Revocation beats validity** — the agent's JWT would pass cryptographic
   checks for another few minutes, yet the gateway refuses it immediately.

Verifying the audit trail afterward:

```bash
docker exec agent-gateway-postgres psql -U agentgw -d agent_gateway \
  -c "SELECT ts, agent_id, action, outcome, reason FROM audit_events ORDER BY ts;"
```

## Demo 2 — graphical (`/demo.html`)

Open **http://localhost:8083/demo.html**. The same nine steps as an
interactive, animated walkthrough for people who prefer visuals:

- the request path lights up (You → SSO → Authz → Tokens → Gateway → Tools)
  as each call happens, with a packet animation
- green / amber / red outcomes with the real HTTP status and body
- a **spend-cap meter** showing €150 inside the cap vs €250 breaching it
- a **live audit feed** recording allow / hold / deny as they occur
- sign-in is one click (the development SSO connector is pre-selected; the
  IdP is relayed by the web tier, so the browser only talks to :8083). The two
  names in it (`alice`, `bob`) are demo IdP fixtures only — with a real
  enterprise IdP in `OIDC_ISSUER_URL` your actual users sign in and the
  console shows \"Signed in as <email> · verified ✓\" bound to the subject; the
  delegation is bound to the verified subject, which the audit trail reflects
- a **Reset** button revokes the delegation and wipes the page so you can run
  it fresh for the next viewer

Tip for presenting: run the scripted demo once in terminal parlance for the
"how it works" crowd, then flip to the browser for decision-makers — the
message is identical, the audience differs.

## Demo 3 — the OPA policy playground (`/policy.html`)

This one needs the policy engine switched on, which is a single extra flag:

```bash
cd demo
docker compose -f docker-compose.yml -f docker-compose.opa.yml up -d
```

Then open **http://localhost:8083/policy.html**. (If you opened it on a stack
started without the override, the page shows a banner with the exact command
above — the playground needs the OPA engine and the shared policy file.) The
page edits the *live*
Rego file the authorization service watches ([`demo/policies/authorizer.rego`](../demo/policies/authorizer.rego)),
applies it, and shows the decisions the **running** engine returns:

1. sign in (one click, no password) in the **Decision probes** panel — it creates
   a probe delegation (scope `/orders`, spend cap €200) and enables **Run all
   probes**;
2. **Run all probes** shows the three canonical outcomes — €150 allowed,
   €250 *held for approval*, `/payments` denied;
3. edit the `spend_breached` rule (the auto-approve cap) in the policy textarea and **Apply** — within five seconds the
   €250 probe flips to *allowed*: that is the hot reload, on the real engine.
   **Apply** compiles your edit first, so if it does not compile you are shown
   the exact compiler error (file, line, message) instead of a silent no-op;
4. **Break it on purpose** writes invalid Rego and applies it — **Apply**
   reports the compiler's refusal straight away, the decisions do not change,
   and the previous policy keeps serving (status turns amber). **Restore initial
   policy** puts the good policy back (it is a
   pristine copy of the tracked `demo/policies/authorizer.rego`; on the host,
   `git restore demo/policies/authorizer.rego` does the same). The page polls the
   file, so a host-side `git restore` shows up on its own; **Reload from file**
   re-reads it on demand.

The message for an audience: guardrails are code you can review and version,
the change is live in seconds without a redeploy, and a mistake cannot take
the gateway down. How it works under the hood: [Policy-and-OPA.md](Policy-and-OPA.md).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Demo reports a service unhealthy | `cd demo && docker compose up -d` and wait ~20 s; check `docker compose ps` |
| `ERROR: Licence has expired on …` at startup | request a fresh licence token from the vendor; replace `demo/keys/license.token` and restart |
| `Customer private key not found` | the images need `demo/keys/` mounted — do not delete that directory |
| SSO sign-in step fails | ensure Dex is up: `curl http://localhost:5556/dex/.well-known/openid-configuration` |
| Graphical demo says tokensvc is down | make sure your compose file from this repo is ≥ the version matching `agent-gateway-web:1.0.18` |

# demoapi — a demo *protected API*

This folder contains a tiny API service that pretends to be **your
(company's) sensitive API** — for example a payments endpoint.

Agent Gateway sits in front of it. Every call an agent makes must pass the
gateway's policy first — and, for sensitive paths, a **human must approve
before the API is allowed to run**.

```
 agent ──call──► Agent Gateway ──allowed?──► demoapi (executes)
                     │
                     └──sensitive?──► HELD (202) … human approves … then runs
```

Two important facts about this folder:

* The image is **plain** (no encryption, no licence token). The other
  images (authz, tokensvc, gateway, console) are vendor-delivered, so they
  arrive encrypted and licence-gated. `demoapi` represents **your** own
  service — you would never license your own code.
* Every response includes `executed_count` — how many times THAT path has
  been executed during this container's life. This turns a claim into
  evidence: after the demo, the sensitive path's counter shows the API ran
  **exactly once** (and only after the approval).

## The Payments-API surface (1.0.5+)

The human-delegation demo (`demo/human-delegation-demo.sh`) needs the API to
*behave* like a payments back end, so 1.0.5 adds a small one on top of the
counting echo (which every other path still gets — Demos 1–4 are unchanged):

| Endpoint | Who calls it | What it does |
|---|---|---|
| `GET /suppliers/{id}` | the agent, via the gateway | supplier master record — the **verified IBAN on file** |
| `GET /invoices/{id}` | the agent, via the gateway | the invoice, enriched with `beneficiary_matches_supplier` (data, not a decision) |
| `POST /invoices` | the demo script, **out of band** | the AP inbox receiving an invoice (agents never have this path; re-registering resets it, so reruns start clean) |
| `POST /payments` | the agent, via the gateway | **executes** a payment — only ever reached after the human's approval |
| `GET /payments` | the demo script, out of band | executed payments + the per-path counter (the exactly-once evidence) |

`POST /payments` keeps controls of its own — the backstop behind the
gateway's human approval: unknown invoice → 404, amount ≠ invoice → 409,
already paid → 409, and a **beneficiary IBAN that does not match the
supplier record → 409 `beneficiary_mismatch`** even if a human approved it.

## Run it (one command)

From this repository's root:

```bash
demo/human-delegation-demo.sh                     # local docker compose stack
demo/human-delegation-demo.sh --no-human          # unattended: fraud denied, legit approved
demo/protected-api-demo.sh --node 192.168.1.74    # the k3s cluster
```

(the cluster needs the namespace deployed first — `k3s/README.md`)

### What you will see, step by step

| # | What happens | Why it matters |
|---|---|---|
| 1 | Sign in at the IdP → a **verified subject** | the human is real, not a claimed name |
| 2 | Create a delegation for agent `openclaw-ap-agent` with an **approval rule** (below) | the human decides, the policy is written with the grant |
| 3 | Agent mints a short-lived token using the one-time secret | short-lived, scoped — not a reusable key |
| 4 | Invoice + supplier reads **run immediately** | low-risk work is never blocked |
| 5 | First `POST /payments` → **202, HELD, not executed** | the `executed_count` did not move: the API never ran |
| 6 | The human sees supplier record vs proposed beneficiary → **deny** (fraud round) | the injected "change of bank details" is visible where the decision is made |
| 7 | The agent retries → **403** | the agent cannot override the human's decision |
| 8 | Legitimate invoice under a fresh delegation → held → **approve** → **200** | single-use, bound to this exact action |
| 9 | Revoke the delegation → next call **403** | instant enforcement, even with the token still valid |

## How "require approval" is switched on

Inside the **delegation** (the human's grant), as an `approval_rules` entry.
Nothing else is configured — no gateway edit, no policy file edit:

```json
{
  "resources": ["/orders", "/api/sensitive*"],
  "actions": ["read", "create"],
  "approval_rules": [
    {
      "when":       { "resource_pattern": "/api/sensitive*" },
      "require":    true,
      "rationale":  "moving money always needs a human"
    }
  ]
}
```

Reading the fields:

* `resources` — which paths the agent may reach at all (everything else is
  denied outright, `403 resource not allowed`).
* `approval_rules[].when.resource_pattern` — **prefix matching**: this rule
  matches every path starting with `/api/sensitive`, e.g.
  `/api/sensitive/payment`.
* `rationale` — the sentence the approver sees in the 202 response and in
  the console/webhook. Write it for the human, not for the log.
* A rule is scoped to the **delegation it belongs to**: the same gateway
  can serve agent A where the sensitive API auto-runs (no rule) and agent B
  where it always needs a human.

Match rules in one line: **exact**, `pre*` (prefix), `*suf` (suffix). To
match "any action", leave `action_pattern` out — writing just `"*"` does
NOT mean "everything".

## Who can approve?

Two independent gates, both must pass:

1. **`X-Admin-Token`** — an operator secret (`GATEWAY_ADMIN_TOKEN`). It is
   given to the console and to trusted automation only. The agent runtime
   never receives it, so an agent literally cannot reach the approve call
   (`401 invalid admin token`).
2. **The delegating user** — the `approver_id` in the decision must equal
   the subject the delegation was created with; the console fills it in
   automatically from your sign-in session. Everyone else: `403 only the
   delegating user can approve`.

Every decision lands in the audit trail with the approver recorded.

## Under the hood (for maintainers)

* Source: `main.go` (single file, Go standard library only — standalone
  `go.mod`), tests: `main_test.go`.
* Image: built from the `Dockerfile` in this directory; plain alpine,
  non-root, multi-arch (it declares `ARG TARGETOS`/`ARG TARGETARCH` — keep
  them!).
* Publish your own copy from this repo root:
  `make push REGISTRY=ghcr.io/yourname IMAGE_NS=your-prefix`
  (compose consumes it via `DEMOAPI_IMAGE=…`, k3s by editing the image ref
  in `k3s/agentgw.yaml`).
* For a smoke test of just this service:
  `go run .` then `curl -s -X POST localhost:8090/demo` — watch
  `executed_count` climb.

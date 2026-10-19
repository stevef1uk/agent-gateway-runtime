# Running the demos

The demos run against the same seven-container stack in [`demo/`](../demo/)
and make **real** calls — nothing is simulated. Run the stack first:

```bash
cd demo
docker compose -f docker-compose.yml -f docker-compose.egress.yml up -d
                            # pulls published images from Docker Hub;
                            # the egress overlay adds the gateway's :8088 proxy (Demos 5–7)
./demo.sh
```

| Endpoint | Status |
|---|---|
| http://localhost:8083 | admin console |
| http://localhost:8083/demo.html | graphical guided demo |
| http://localhost:8083/policy.html | OPA policy playground *(needs the policy override — see Demo 3)* |
| http://localhost:8080 | gateway (PEP) — what your agents call |
| http://localhost:8088 | gateway egress proxy (needs the egress overlay — Demos 5–7) |
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

## Demo 4 — the protected API (`demoapi`, scripted)

`demo/protected-api-demo.sh` plays the whole protected-API story from the shell
against the `demoapi` upstream: a delegation's **approval rule** holds a
sensitive call **before it executes**, a human approves, the retry runs exactly
once, then revocation denies everything after. It needs only `curl` and
`python3`, and the stack must already be up ([`demo/`](../demo/) — compose mode
is the default).

### Run it

For compose, the stack must already be up (base + egress overlay, the same
stack the other demos use):

```bash
cd demo && docker compose -f docker-compose.yml -f docker-compose.egress.yml up -d
cd ..
demo/protected-api-demo.sh                        # compose, scripted approval
demo/protected-api-demo.sh --await-human          # stop at the hold: YOU approve

demo/protected-api-demo.sh --node 192.168.1.74            # k3s cluster (namespace agentgw)
demo/protected-api-demo.sh --node 192.168.1.74 --await-human
```

By default the script plays *both* roles — it creates the hold, then approves as
the delegating user — so it runs unattended. With **`--await-human`** it stops
at the held call instead and polls the gateway for up to 360 s: approve on the
**Telegram card** (or in the console) and the retry executes once; deny and
nothing runs. Wiring up the card is covered in
[Notifications.md](Notifications.md).

### Flags

| Flag | Meaning |
|---|---|
| `--node <ip>` | target the k3s cluster at `<ip>` (NodePorts 30080–30083) instead of local compose |
| `--await-human` | stop at the hold and wait for a human verdict, instead of auto-approving |

### Endpoint / secret overrides (env)

| Variable | Default (compose · `--node`) | Meaning |
|---|---|---|
| `WEB` | `http://localhost:8083` · `http://<node>:30083` | console / SSO base URL |
| `GW` | `http://localhost:8080` · `http://<node>:30080` | gateway (PEP) base URL |
| `AUTHZ` | `http://localhost:8081` · `http://<node>:30081` | authz service base URL |
| `TS` | `http://localhost:8082` · `http://<node>:30082` | token service base URL |
| `ADMIN_TOKEN` | `agent-gateway-demo-admin` | operator token used for the approval call |
| `AWAIT_HUMAN` | `0` | set to `1` for the same behaviour as `--await-human` |

`--node` sets `WEB`/`GW`/`AUTHZ`/`TS` for you; an explicit env value wins.

What it proves, and how:

1. **SSO** → the delegation is created *with an `approval_rules` entry*:
   `{"when":{"resource_pattern":"/api/sensitive*"},"require":true,"rationale":"sensitive API access requires a human"}` —
   policy-as-code at delegation time; no gateway or policy file is edited.
2. **Low-risk call runs immediately**: `/orders` forwards to demoapi and the
   response carries the demoapi call counter.
3. **The protected call is HELD**: the first `POST /api/sensitive/payment`
   returns **202 + approval record** — and demoapi's `executed_count` did
   not move: the upstream genuinely was not called. This is the
   *require-approval-before-execution* property, not merely "money held".
4. **Only the delegating user can approve**: a different human ("mallory")
   using the same operator token is refused (`403`, approver binding).
5. **The retry executes exactly once**: after the bound subject approves,
   the response counter increments by one — then **revocation** denies any
   further call at the enforcement point (403), even with the token still
   cryptographically valid.

The component itself (and why it is a plain, un-licenced image) is
documented in the same repository, at `demo/api/README.md`.

## Demo 5 — all outbound egress via the gateway, approved per call (`demo/egress-demo.sh`)

The newest demo exercises the **egress proxy**: an agent runtime whose
*every* outbound destination becomes one authorization decision —
destination host is the resource, HTTP method (or CONNECT) is the action —
identical guarantees to the tool path (revocation first, human approval for
each call, audit for every allow/deny).

```bash
cd demo
# enable the listener first (images >= gateway 1.0.22; the pinned public
# images gain it when the version lands on Docker Hub; locally:
#   make image-gateway   # from the agent-gateway repo, then point
#                        # docker-compose at the local tag
docker compose -f docker-compose.yml -f docker-compose.egress.yml up -d
./egress-demo.sh
```

What you will see, step by step:

1. posture check — an unauthenticated request to the proxy is refused
   (407): it is never an open relay
2. SSO sign-in (same Dex machinery as `demo.sh`)
3. an egress delegation: `example.com` only, `[read, connect]`, with the
   approval rule `*` → **every outbound call needs a human decision**
4. token minting (the JWT doubles as the `Proxy-Authorization` bearer)
5. read call → **202 held** until approved (Telegram card / console entry
   appear at the same moment) → approve → the same call **200**
6. an undelegated host → **403 policy_denied**, no human involved
7. HTTPS CONNECT tunnel → **202 held** on the *connect* action → approve →
   `200 Connection established` (TLS stays end to end; the gateway saw the
   destination, never the payload)
8. delegation revoked → even the tunnel answers **403** instantly

Notes:

* `demo/egress-demo.sh` speaks the CONNECT leg through a raw socket, because
  `curl` treats a non-200 CONNECT response as a failed tunnel and hides the
  proxy's real answer.
* Approvals expire (~15 min) — the demo approves immediately; a hold you
  leave unanswered disappears from the console when it expires and the
  next call raises a fresh one.
* On approval cards: the Telegram cards include a console deep-link only
  when `APPROVAL_CONSOLE_URL` is set to a *routable* address (the listener
  `demo/docker-compose.egress.yml` sets it to the machine's LAN URL).

## Demo 6 — OpenClaw confined to an OpenShell sandbox (`demo/openclaw-sandbox.sh`)

Runs the whole agent — process, filesystem, network — inside an
[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) sandbox, then chats
with it. This is the sandbox-step-only path: it proves isolation and a working
model call, without the Agent Gateway egress proxy.

```bash
# needs Docker + the openshell CLI + NVIDIA_API_KEY in demo/.env
make openclaw-demo
```

> Signing in at the console (approval decision / Telegram-card link) on a LAN
> address, not `localhost`? The bring-up runs `demo/refresh-dex-redirects.sh`
> for you (see its `DEX_EXTRA_IPS` override for foreign devices).

What you will see:

1. the image builds (Ubuntu 24.04 + Node 22 + OpenClaw, non-root `sandbox`
   user, provider config baked in with the key as an env SecretRef)
2. the sandbox is created and the OpenClaw gateway starts as its main process
3. `configure` writes the provider config and applies the default-deny egress
   allowlist (model provider + OpenClaw catalog, no `::tcp`)
4. a chat turn returns a real reply from the model

Full walkthrough, required flags, model selection and troubleshooting:
[OpenClaw-OpenShell.md](OpenClaw-OpenShell.md).

## Demo 7 — prove the sandbox's egress rules (`demo/openclaw-egress-test.sh`)

The scripted gate for Demo 6's network story: it asks **OpenClaw itself** to
fetch an allowed host, a blocked host and the OpenClaw telemetry host, then —
with **`--gateway`** — drives the Agent-Gateway loop against the real upstream
(`api.github.com`): CONNECT held (`202`-shape/approval id), auto- or
human-approved, executed exactly once, single-use rebind on a second connect.

```bash
./demo/openclaw-egress-test.sh                       # sandbox policy alone
make openclaw-egress-test GW=--gateway               # + Agent-Gateway checks (you approve)
GW="--gateway --no-human" make openclaw-egress-test  # unattended: every hold auto-approved
```

Needs only the stack + the sandbox (`make openclaw-demo` first); `--no-human`
makes it CI-safe. Step-by-step: [OpenClaw-OpenShell.md](OpenClaw-OpenShell.md).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Demo reports a service unhealthy | `cd demo && docker compose up -d` and wait ~20 s; check `docker compose ps` |
| `ERROR: Licence has expired on …` at startup | request a fresh licence token from the vendor; replace `demo/keys/license.token` and restart |
| `Customer private key not found` | the images need `demo/keys/` mounted — do not delete that directory |
| SSO sign-in step fails | ensure Dex is up: `curl http://localhost:5556/dex/.well-known/openid-configuration` |
| Graphical demo says tokensvc is down | make sure your compose file from this repo is ≥ the version matching `agent-gateway-web:1.0.18` |

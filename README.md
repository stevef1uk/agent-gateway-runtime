# Agent Gateway — AI agents work, humans stay in control

<p align="center">
  <img src="images/conceptual.png"
       alt="Agent Gateway conceptual architecture — an end user signs in through an OIDC provider (Dex / Keycloak / Entra / Okta); the Web UI + Authz service manages delegations, decisions and approvals; the token service issues short-lived, audience-scoped JWTs; the AI agent runtime presents its SPIFFE ID while calling the policy enforcement gateway (PEP) that validates identity, delegation, action, limits, approval and audit before proxying authorized, audited requests to downstream APIs and enterprise systems. Key security principles: distinct identities, delegated time-bound authorization, short-lived scoped tokens, policy enforcement, risk-based approvals, full audit — standards include OpenID Connect, OAuth 2.0 token exchange, Rich Authorization Requests, DPoP/mTLS and SPIFFE/SPIRE workload identities."
       width="844">
</p>

> **Status note on the diagram.** Two panels describe the target design and
> are **not implemented yet**: **DPoP / RFC 9449** (sender-constrained,
> key-bound tokens) and **Rich Authorization Requests / RFC 9396**
> (structured negotiation of fine-grained permissions at the token endpoint).
> Everything else shown — OIDC sign-in (Dex ships; Keycloak / Entra / Okta
> connect via `OIDC_ISSUER_URL`), delegations, RFC 8693 token exchange,
> short-lived scoped tokens, the PEP with approval + audit, SPIFFE/SPIRE
> workload identity — is live in the shipped images. Progress is tracked in
> the project's roadmap; Production deployments relying on either panel
> should ask the vendor before designing around them.

> 📑 **Reading the docs:** all links in this README are relative so the
> repository stays portable. If a documentation link lands on a 404 in your
> git server's front page, open `README.md` **from the file view**
> (`…/src/branch/main/README.md`) or browse the `docs/` folder — the same
> relative paths resolve correctly there (and always will on GitHub).

> 🚧 **Early preview — and your feedback sets the direction.** Agent Gateway
> is a **new project**, published so you can pull it, run it and try it.
> Nothing here is frozen: what gets built next (agent-request flows,
> fine-grained delegations, per-tool MCP enforcement, DPoP/RAR…) is decided
> largely by what users tell us matters. If you run the demos, deploy it to
> your own stack, or just disagree with a design choice — write to
> **steve@sjfisher.com** or open an issue on this repository; both go
> straight into the roadmap. Everything is free (including a non-expiring
> licence by email) — see [Pricing](#pricing).

**Public demo repository.** Pull the pre-built Docker images, run one compose
stack, and see a complete authorization system for AI agents live: SSO
delegations, short-lived agent credentials, spend caps with automatic
approvals, single-use human approvals for high-risk actions, instant
revocation, and an immutable audit trail.

> 💡 **Fastest path:** [Quickstart](#quickstart) → two minutes to a running
> stack. Then run the demos ([scripted](#demo-1---scripted),
> [graphical](#demo-2---graphical) and
> [policy playground](#demo-3---the-opa-policy-playground)).

## The problem, in one paragraph

AI agents call tools that do real things — payments, deployments, data
exports. "Trust me, the agent knows what it's doing" is not a control you can
put in front of an auditor. Agent Gateway puts a **policy enforcement point**
in front of every tool call:

1. **A human delegates** — after signing in with SSO (OIDC), you grant an
   agent exactly-scoped rights: *these paths, these actions, this auto-approve
   cap, this expiry*. Least privilege by construction; the delegation is
   cryptographically bound to your verified identity.
2. **Agents work fast** — low-risk actions execute automatically, no human in
   the loop. The 80% of agent traffic that is safe shouldn't wait.
3. **High-risk actions stop — and reach a human** — anything above the cap
   returns *held for approval*. Money hasn't moved. The gateway pushes an
   HMAC-signed `approval.required` webhook to your automation (Slack, Teams,
   n8n, PagerDuty — setup in [docs/Notifications.md](docs/Notifications.md)),
   or push a card straight into a **Telegram** chat; the console also shows a
   pending badge, so the human is told, not polled. A named human approves
   (or denies) the exact action hash — single-use, replay-proof.
4. **Revocation is instant** — revoke the delegation and even an
   unexpired, correctly-signed agent token is refused at the gateway. Token
   validity ≠ authorization.
5. **Everything is audited** — allow, hold, deny, approval, approver — one
   immutable record per decision, ready for your SIEM.

## Architecture

```
              OIDC (Okta / Entra / Keycloak / Dex)
 Human ──────────────► ┌─────────────────────────────┐
                       │  authz   (decision point)   │  delegations, policy,
                       │           :8081             │  user identity (OIDC)
                       ╰──────────┬──────────────────╯
                                  │ mint scoped token
                       ┌──────────▼──────────────────┐
 AI Agent ──token──►   │  gateway (enforcement point)│  every call: resolve
                       │           :8080             │  principal → policy →
                       ╰──────────┬──────────────────╯  approve? → audit
                                  │ forward only if allowed · held → approval.required webhook
                       ┌──────────▼──────────────────┐
                       │  your tools / internal APIs │
                       ╰─────────────────────────────┘

 Held for approval? The gateway pushes an HMAC-signed approval.required
 webhook to your automation (Slack / Teams / n8n / PagerDuty — setup in
 [docs/Notifications.md](docs/Notifications.md)); the console shows a
 pending badge + toast.

 Supporting services:
   tokensvc :8082   mints short-lived, delegation-scoped JWTs
   web      :8083   admin UI: delegations, approvals, audit + guided demo
   postgres :5432   durable store (delegations, approvals, audit)
   redis    :6379   instant token revocation + decision cache
```

Deep dive: [docs/Architecture.md](docs/Architecture.md).

## What this repo contains

| Path | What it is |
|---|---|
| [`demo/`](demo/) | One-command demo stack: `docker-compose.yml`, Dex config, demo keys, scripted walkthrough (`demo.sh`), the default OPA policy (`policies/`) with a policy-engine override (`docker-compose.opa.yml`), and the performance benchmark (`bench/`, `bench-engines.sh`) |
| [`docs/Deployment-Guide.md`](docs/Deployment-Guide.md) | From Docker Hub images to a highly available enterprise deployment (Kubernetes, OIDC against any IdP, SPIFFE mTLS, Postgres/Redis HA, SIEM integration) |
| [`docs/Agent-Identity.md`](docs/Agent-Identity.md) | How proliferating agents are admitted, what stops name-impersonation, the credential ceremony |
| [`docs/Integration-Patterns.md`](docs/Integration-Patterns.md) | Inserting the gateway between existing agents and back ends/MCP servers with zero or one-line changes |
| [`docs/Local-Agents.md`](docs/Local-Agents.md) | Personal/local agent runtimes (OpenClaw, Hermes, your own) — per-skill delegations, MCP adapter, spend caps, phone-side revoke |
| [`docs/Architecture.md`](docs/Architecture.md) | How the pieces fit, the policy model, security properties |
| [`docs/Policy-and-OPA.md`](docs/Policy-and-OPA.md) | Policy as code: the OPA/Rego engine — decision contract, authoring, testing, hot reload |
| [`docs/Protecting-Your-API.md`](docs/Protecting-Your-API.md) | Hands-on guide for new users: every constraint you can configure on a delegation, what the built-in engine enforces directly, what needs OPA, and the limitations to design around |
| [`docs/Benchmarking.md`](docs/Benchmarking.md) | Measuring gateway performance — allowed vs denied passthroughs, built-in vs OPA engine, how to run and read it |
| [`docs/Demos.md`](docs/Demos.md) | Runbook for the demos and what each step proves |
| [`demo/protected-api-demo.sh`](demo/protected-api-demo.sh) | Demo 4 — the protected-API demo: an approval rule holds calls to `demoapi` until the delegating user approves; works on compose and k3s |
| [`demo/egress-demo.sh`](demo/egress-demo.sh) | Demo 5 — all outbound traffic through the gateway's egress proxy: destination host = one authorization decision per call, human approval on each one (needs images ≥ gateway 1.0.22 with `GATEWAY_PROXY_ADDR=:8088`); the OpenShell/OpenClaw integration guide lives in the main repo |
| [`docs/Security-and-Licensing.md`](docs/Security-and-Licensing.md) | How image encryption + vendor licence + your keys work at runtime |
| [`docs/Commercial-Licence.md`](docs/Commercial-Licence.md) | Licence terms: what you get, what is not warranted, liability limits, indemnity |
| [`docs/Pricing.md`](docs/Pricing.md) | Licensing tiers and buying path |
| `LICENSE` | MIT for this repository's documentation and demo assets |

## Quickstart

Requirements: Docker Engine 24+, `docker compose`, `curl`, `jq` optional.

### Building and publishing the demo API yourself

The gateway-stack images ship from the product repo. The **demo API** lives
here (`demo/api/`, standalone module) and is rebuilt with the repo Makefile:

```bash
make image                     # host arch into the local engine
make push                      # multi-arch (amd64+arm64) → REGISTRY/IMAGE_NS
make verify-arch               # assert an arm64 variant actually runs arm64 code
```

To publish to your own registry:
`make push REGISTRY=ghcr.io/yourname IMAGE_NS=your-prefix` — then consume it:
- compose: `DEMOAPI_IMAGE=ghcr.io/yourname/your-prefix-demoapi:1.0.3 docker compose -f demo/docker-compose.yml -f demo/docker-compose.opa.yml up -d`
- k3s: change the `demoapi` image ref in `k3s/agentgw.yaml` to your registry.


> Also available on Kubernetes: [`k3s/`](k3s/) deploys the same stack into a
> k3s/`kubectl` cluster (own namespace `agentgw`, NodePorts, the live-policy
> shared volume) — see [`k3s/README.md`](k3s/README.md). The console, guided
> demo and policy playground all run untouched at `http://<node>:30083`.

```bash
cd demo
docker compose up -d          # 7 containers, first pull takes a minute
./demo.sh                     # scripted end-to-end walkthrough
```

Then open:

| URL | What |
|---|---|
| http://localhost:8083/demo.html | **Graphical guided demo** (animated, interactive — great to show people) |
| http://localhost:8083 | Admin console: create/revoke delegations, decide approvals, full audit trail |
| http://localhost:8083/policy.html | **OPA policy playground** — edit the live Rego policy and watch hot reload (needs `demo/docker-compose.opa.yml`) |
| http://localhost:8080/v1/* | The gateway itself — this is the endpoint your agents call |

The bundled development SSO has two fixture human accounts (`alice@example.com`,
`bob@example.com`) — they exist only in the demo IdP so logins work with no
setup. In production you point `OIDC_ISSUER_URL` at your own enterprise IdP;
your real users sign in with corporate credentials and the console instead
shows **"Signed in as <email> · verified ✓"** bound to the verified subject.

Everything runs from published images on Docker Hub
(`stevef1uk/agent-gateway-{authz,gateway,tokensvc,web}`) — no source, no build.
The included `demo/keys/` are development fixtures matching the keys baked into
those images; regenerate through the vendor for your own customers
([Security-and-Licensing.md](docs/Security-and-Licensing.md)).

## Demo 1 — scripted

```bash
cd demo && docker compose up -d
./demo.sh
```

See it walk the *entire story* live, step by step — SSO sign-in → delegation →
agent token → €150 order auto-allowed (HTTP 200) → €250 order held (HTTP 202 +
approval id) → you approve → order executes → revoke → next agent call denied
(HTTP 403) with the token still valid on the wire.

## Demo 2 — graphical

Open **http://localhost:8083/demo.html** on the same stack.

Nine interactive steps with animated request flows, a live spend-cap meter,
health pills for every service and a live audit feed. Sign-in is one click (the IdP is relayed by the web tier — no /etc/hosts or extra setup on your machine) and
all calls are real — nothing simulated. This is the demo to run on screen in a
meeting.

## Demo 3 — the OPA policy playground

Bring the stack up with the policy engine switched on:

```bash
cd demo
docker compose -f docker-compose.yml -f docker-compose.opa.yml up -d
```

Then open **http://localhost:8083/policy.html**. It shows the live Rego policy
the authorization service is enforcing, lets you edit and apply it, and runs
decision probes against the **running** engine — so you watch the hot reload
take effect in seconds. **Apply** compiles your edit first, so an edit that does
not compile is called out with the exact compiler error instead of appearing to
do nothing; breaking the policy on purpose is refused and the previous policy
keeps serving; **Restore initial policy** puts the committed
version back, and **Reload from file** re-reads it after a host-side
`git restore` (the page also refreshes itself when the file changes on disk).
Full story: [docs/Policy-and-OPA.md](docs/Policy-and-OPA.md) and
[docs/Demos.md](docs/Demos.md).

## Demo 4 — the protected API (`demoapi`)

A stand-in for a **customer's own API** — deliberately a plain image (no
licence/encryption) since it represents *your* service, not a vendor part.
Run it:

```bash
./demo/protected-api-demo.sh                      # compose (default)
./demo/protected-api-demo.sh --node 192.168.1.74  # k3s cluster
```

By default the script auto-approves as the delegating user so it runs
unattended; add **`--await-human`** to stop at the hold and approve on the
Telegram card (or in the console) yourself.

The delegation carries an **`approval_rules`** entry
(`resource_pattern:/api/sensitive*, require:true`) — so the first call to the
sensitive API is **held (202) and never executes**: demoapi's per-path
`executed_count` counter proves the upstream did not run. `mallory` (any
other human) is refused even with the operator token; the **delegating user**
approves (subject-bound), the retry executes **exactly once** (counter ↑ by
1), and revocation kills the call path instantly. Walkthrough text, the full
flag list and the endpoint/env overrides:
[docs/Demos.md](docs/Demos.md); the component's source, Dockerfile and
detailed README live right here in [`demo/api/`](demo/api/README.md).

## Demo 5 — all outbound egress via the gateway, approved per call

For runs on the same stack, an extra demonstration: egress enforcement
(one authorization decision per outbound destination, human approval for
each, audit for everything):

```bash
cd demo
docker compose -f docker-compose.yml -f docker-compose.egress.yml up -d
./egress-demo.sh      # needs images >= gateway 1.0.22 (GATEWAY_PROXY_ADDR=:8088)
```

407 at the door without credentials → the read call held (202) until you
approve → an undelegated host refused outright (403) → the TLS CONNECT
tunnel held on the `connect` action, then opened (blind, TLS end to end) →
revocation is instant. Full walkthrough:
[docs/Demos.md](docs/Demos.md §Demo-5); the OpenShell/OpenClaw integration
(what makes the gateway the *shell* around agents) lives in the main repo's
[`OpenShell-Integration.md`](https://github.com/stevef/agent-gateway/blob/main/OpenShell-Integration.md).

## Performance

The gateway is a policy enforcement point in front of every agent call, so its
per-request cost matters. This repo ships a benchmark that measures an
**allowed** passthrough (200, proxied upstream) and a **denied** one (403, no
upstream), for both policy engines:

```bash
cd demo && docker compose up -d
make bench            # or: ./demo/bench-engines.sh
```

It prints throughput and p50/p90/p99 latency per path and auto-detects the
engine in use (built-in vs OPA). Flags, reference numbers and how to point it
at k3s or read the JSON output: [docs/Benchmarking.md](docs/Benchmarking.md).

## URLs & endpoints (demo stack)

| Service | URL |
|---|---|
| Web console | http://localhost:8083 |
| Guided demo (graphical) | http://localhost:8083/demo.html |
| OPA policy playground | http://localhost:8083/policy.html *(needs the policy override)* |
| demoapi (protected API) | http://localhost:8090 — only reachable OUT OF BAND; the gateway forwards to it, so normal traffic must go through :8080 |
| Gateway (PEP) | http://localhost:8080 |
| Gateway egress proxy | http://localhost:8088 — *opt-in*: publish + `GATEWAY_PROXY_ADDR=:8088` on the gateway service; routes every outbound call of an agent (e.g. an NVIDIA OpenShell sandbox running OpenClaw) through delegation-scoped per-request authorization + approval |
| Authz service | http://localhost:8081 |
| Token service | http://localhost:8082 |
| OIDC provider (Dex) | http://localhost:5556 |

## Using it for real

Pointing it at **your** API? [docs/Protecting-Your-API.md](docs/Protecting-Your-API.md)
walks through the delegation fields and the constraints you can set — directly
or via OPA — with a worked example.

When you are done playing: [docs/Deployment-Guide.md](docs/Deployment-Guide.md)
covers production operation of the same images — Postgres/Redis HA, Kubernetes,
any OIDC IdP, SPIFFE/workload identity (mTLS), licence lifecycle, upgrade
procedures and a troubleshooting reference.

## Pricing

The product is **free** — including a non-expiring licence token by email.
What is paid is the author's time and commercial terms:

| Tier | Price | What you get |
|---|---|---|
| Users & Developers | **free** | full product, non-expiring licence by email, community support |
| Business | **book me for a week** | hands-on deployment, IdP/agent/HA integration with your team, enablement |
| Software Licence | €5,000 one-off | full source, royalty-free, perpetual |

Support is email at every tier, best-effort — no SLA at this stage.
Every tier runs under the same commercial licence (AS-IS, no fitness
warranty, liability capped — see [docs/Commercial-Licence.md](docs/Commercial-Licence.md)).
Details and rationale: [docs/Pricing.md](docs/Pricing.md).

## License

Documentation and demo assets in this repository: MIT (see `LICENSE`).
The software itself is distributed as pre-built Docker images under a
commercial licence from the vendor — terms, warranty disclaimer and
liability limits at [docs/Commercial-Licence.md](docs/Commercial-Licence.md).
In brief: the software is provided **AS IS, with all faults, without warranty
of fitness for any particular purpose**; you evaluate it before production
use; liability is capped at fees paid in the preceding 12 months (nil on free
tiers); and every consequential action an agent takes under a delegation
remains your organisation's responsibility.

## OpenShell integration

For users of the OpenShell mobile agent framework: this repository contains
helper scripts to run an agent **inside** an OpenShell sandbox, and to
register the local Agent Gateway as an OpenShell upstream proxy so that
sandbox's egress is governed.

| Path | What it does |
|---|---|
| [`demo/openclaw-sandbox.sh`](demo/openclaw-sandbox.sh) | Run OpenClaw confined to an OpenShell sandbox: build the image, create the sandbox, configure the model provider + egress allowlist, and chat. `make openclaw-demo` runs the whole path. **Start here** — see [docs/OpenClaw-OpenShell.md](docs/OpenClaw-OpenShell.md) |
| [`demo/openshell-gateway-setup.sh`](demo/openshell-gateway-setup.sh) | One-command OpenShell + Agent Gateway prep: register the local gateway, write the token to `~/.config/openshell/upstream-proxy-auth`, create the delegation for normal provider traffic, and apply the sandbox policy to the active OpenClaw runtime |
| [`demo/openshell.sh`](demo/openshell.sh) | Verifies the allow-path and approval-gated paths using the delegation described above |

To run an agent inside a sandbox:

```bash
make openclaw-demo        # build → sandbox → provider → chat
```

Then, to govern that sandbox's egress through the Agent Gateway:

```bash
cd demo
./openshell-gateway-setup.sh
```

Then follow the [OpenShell quickstart](https://github.com/stevef/openshell/blob/main/README.md#quickstart)
to install OpenShell, import the gateway as an upstream proxy, and run the
sandbox.

The default delegation and policy are designed for demonstration and testing
only; review and adjust them for your production use. See
[docs/Integration-Patterns.md](docs/Integration-Patterns.md) for details on
how to wire existing agents and back ends to the gateway.

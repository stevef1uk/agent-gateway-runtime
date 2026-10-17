# Benchmarking gateway performance

*"Approvals and audit are one thing — but this sits in front of every agent
call. What does it cost? How fast is the allow path, and how fast is a deny?
And how much slower is it when we run policy through OPA?"*

This page documents the benchmark for the **policy enforcement point (PEP)**:
the gateway's per-request cost for an authorized call and for a refused one.
It is quick to run against the demo stack, and it reports the two numbers that
matter in front of a fleet of agents — **throughput** (requests/second) and
**latency** (mean and p50/p90/p99) — for two paths:

| Path | What happens | Expected result |
|---|---|---|
| **allowed passthrough** | token verified → authz decision (*allow*) → request **proxied** to the upstream API | `200` |
| **denied passthrough** | token verified → authz decision (*deny*) → request **refused at the gateway**, no upstream call | `403` |

The gap between them is the cost of the network hop to your tool. The absolute
figures tell you what the enforcement layer itself adds.

## What the harness does

The tool is a single, self-contained Go program (standard library only) that
drives the gateway exactly as a real agent would:

1. **Signs in** over OIDC using the demo IdP's **mock connector** (one-click,
   no credentials) and captures the ID token.
2. **Creates a delegation** for a throwaway agent, scoped to the allowed path.
3. **Mints a short-lived access token** for that delegation.
4. **Auto-detects the policy engine** (`basic` or `opa`) from the decision's
   `policy_id`.
5. Runs a **warmup** (discarded) and then the measured phase for each path,
   with a fixed number of concurrent workers, reusing one token throughout.

Because it reuses a single valid token, the numbers isolate the **enforcement +
decision + proxy** cost — not token minting. Requests still in flight when the
phase deadline fires are dropped and are **not** counted as errors.

## Quick start

Everything is in this repository: the tool is the standalone Go module at
[`demo/bench`](../demo/bench/), and a driver benchmarks both engines in turn.

```bash
cd demo
docker compose up -d          # the built-in engine stack
cd ..
make bench                    # both engines: built-in, then OPA
```

`make bench` runs the comparison driver
([`demo/bench-engines.sh`](../demo/bench-engines.sh)), which benchmarks **both
policy engines** in turn — built-in first, then the OPA override — and leaves
the stack on the built-in engine when it finishes:

```bash
./demo/bench-engines.sh                 # default: -c 20 -d 10s -w 2s
./demo/bench-engines.sh -c 50 -d 30s    # heavier / longer
```

If you only want one run against whatever stack is currently up, call the tool
directly:

```bash
cd demo/bench
go run .                                # defaults: -c 20 -d 10s -w 2s
go run . -c 50 -d 20s
```

> **Requirements.** Go 1.26+ (to build the tool) and a running demo stack, since
> the harness signs in through the demo IdP's mock connector. Against a
> stack with a real IdP you would mint the agent token another way — the
> measurement itself is engine- and IdP-agnostic.

## Reading the output

```
engine=basic gateway=http://localhost:8080
path                    conc  reqs    rps      mean    p50     p90     p99     max      errors  status
allowed POST /orders    20    73469   12242.4  1.62ms  1.54ms  2.11ms  2.79ms  15.62ms  0       200:73469
denied POST /mail/send  20    100961  16825.1  1.17ms  1.12ms  1.50ms  2.08ms  6.50ms   0       403:100961
```

| Column | Meaning |
|---|---|
| `conc` | concurrent in-flight requests (workers) |
| `reqs` | requests completed in the measured window |
| `rps` | throughput (requests/second) |
| `mean`, `p50`, `p90`, `p99`, `max` | latency distribution across all requests |
| `errors` | transport/harness failures (deadline-in-flight requests are excluded) |
| `status` | response-code counts — should be a single code per path |

A healthy run shows **`errors 0`** and one status code per row. A stray `502`,
`5xx`, or a non-empty `errors` column under load is a real signal — and is
exactly what the benchmark is for (see below).

## Comparing the two policy engines

The built-in engine evaluates the table-driven rules in Go. The OPA engine
evaluates a Rego file by shelling out to the `opa` binary **per decision**
(see [Policy-and-OPA.md](Policy-and-OPA.md) → *Operational notes*). On the
author's 16-core host, one compose stack, `-c 20 -d 10s`:

| Engine | Path | rps | mean | p99 |
|---|---|---|---|---|
| **built-in** | allowed `POST /orders` | ≈ 12 000 | ≈ 1.6 ms | ≈ 2.9 ms |
| **built-in** | denied `POST /mail/send` | ≈ 16 500 | ≈ 1.2 ms | ≈ 2.3 ms |
| **OPA** | allowed `POST /orders` | ≈ 770 | ≈ 26 ms | ≈ 42 ms |
| **OPA** | denied `POST /mail/send` | ≈ 790 | ≈ 25 ms | ≈ 40 ms |

Read that as: the built-in engine adds **~1–2 ms** on top of the upstream hop,
while OPA adds **~25 ms** — an order of magnitude, because every decision forks
a process. **OPA is the right engine when you want full Rego expressiveness;
the built-in engine is the right default when throughput matters.** Both enforce
the same contract, revocation and expiry identically.

These figures are **illustrative, not a specification** — they depend on your
CPU, the upstream's own latency, and the network between gateway and authz.
Run it on your own hardware for your own numbers.

## Options

Every knob is a flag; the driver passes the first three through as `-c/-d/-w`.

| Flag | Default | Purpose |
|---|---|---|
| `-c` | `20` | concurrency (parallel in-flight requests) |
| `-d` | `10s` | measured duration per path |
| `-w` | `2s` | warmup duration per path (discarded) |
| `-gateway` | `http://localhost:8080` | the system under test |
| `-web` | `http://localhost:8083` | console (SSO sign-in) |
| `-authz` | `http://localhost:8081` | authz service (delegation) |
| `-tokensvc` | `http://localhost:8082` | token service (mint) |
| `-allow-path` / `-allow-method` / `-allow-body` | `/orders` / `POST` / `{"amount":100,…}` | the authorized request |
| `-deny-path` / `-deny-method` / `-deny-body` | `/mail/send` / `POST` / `{}` | the refused request |
| `-allow-expect` / `-deny-expect` | `200` / `403` | expected status (preflight fails loudly if wrong) |
| `-agent-id` | `bench-agent` | agent id for the throwaway delegation |
| `-engine` | *(auto)* | pin the engine label; otherwise detected from authz |
| `-token-ttl` | `30m` | access-token TTL |
| `-json` | `false` | machine-readable output |

A **preflight** issues one request per path before the timed run and aborts with
a clear message if the allowed path is not `200` or the denied path is not
`403` — usually a sign the delegation scope and the paths disagree.

## Pointing it at another stack

Any deployment works; give it the four base URLs. For the k3s cluster (NodePorts
`30080`–`30083`):

```bash
cd demo/bench
go run . \
  -gateway http://192.168.1.74:30080 \
  -web     http://192.168.1.74:30083 \
  -authz   http://192.168.1.74:30081 \
  -tokensvc http://192.168.1.74:30082 \
  -c 50 -d 20s
```

## In CI (JSON)

`-json` emits the full result — engine, per-path percentiles, statuses — so a
pipeline can assert on it (e.g. fail if `errors > 0` or p99 regresses):

```bash
cd demo/bench && go run . -c 50 -d 30s -json
```

```json
{
  "gateway": "http://localhost:8080",
  "engine": "basic",
  "concurrency": 50,
  "results": [
    {"name": "allowed", "path": "/orders", "rps": 12081.2, "mean_ms": 1.64,
     "p50_ms": 1.55, "p90_ms": 2.12, "p99_ms": 2.85, "errors": 0,
     "statuses": {"200": 120835}}
  ]
}
```

## What the benchmark caught

This harness is not just a scoreboard — it earned its keep by exposing three
real defects in gateway `1.0.21`, all of them invisible to functional tests:

- the authz client and the **upstream proxy hop** both used the stdlib default
  transport (two idle connections per host), so under concurrency the gateway
  churned connections and drained the ephemeral-port range — surfacing as
  spurious `403`s and `502`s;
- the **audit writer** used the request context, so once a response was sent the
  write was canceled (`audit write: context canceled`).

Sizing the keep-alive pools and detaching the audit write took the allowed path
from ~2.8 k rps *with ~1% `502`s* to ~12 k rps with **zero** errors. Run the
benchmark after any change to enforcement, authz or the proxy path.

## Where to go next

- [Policy-and-OPA.md](Policy-and-OPA.md) — the two engines, the decision contract, and why OPA is a per-decision subprocess
- [Architecture.md](Architecture.md) — the request path these numbers measure
- [Demos.md](Demos.md) — the functional walkthroughs (allow / hold / approve / deny)
- [Deployment-Guide.md](Deployment-Guide.md) — production sizing, HA, and operational env vars

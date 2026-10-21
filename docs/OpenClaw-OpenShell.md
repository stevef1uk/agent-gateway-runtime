# Running OpenClaw inside an NVIDIA OpenShell sandbox

*Build an always-on agent whose whole process is confined to a sandbox — no
host filesystem, no Docker socket, default-deny egress — then chat with it.*

This demo puts the **agent itself** on the other side of a trust boundary
instead of trusting it. [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell)
supplies the boundary: it replaces the image entrypoint with its own
supervisor, runs your command as an unprivileged user in a container with its
own network namespace, and enforces a default-deny egress policy. OpenClaw runs
as that command.

## Prerequisites

| Need | Check |
|---|---|
| Docker | `docker version` — for the Advanced egress layering, a current engine (≥ ~29): older moby (26.x) hits the `getent unable to find entry "1001:1001"` bug in `sandbox create` |
| OpenShell CLI | `openshell --version` — see install below; **0.1.x required** for the Advanced egress layering (schema-v2 config) |
| An NVIDIA API key | in `demo/.env` as `NVIDIA_API_KEY=nvapi-…` |

The key is read from `demo/.env` (gitignored). You can also export
`NVIDIA_API_KEY` directly, or point at any OpenAI-compatible endpoint with
`PROVIDER_BASE_URL` / `PROVIDER_MODEL`.

### Installing OpenShell

**macOS (official installer — recommended):**
```bash
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
```
This installs openshell + openshell-gateway (0.1.4 at the time of writing) from
NVIDIA's Homebrew tap (`nvidia/openshell`) and registers a **brew service**
(label `sh.brew.openshell`) that runs the gateway for you, with its PKI in
`/opt/homebrew/var/openshell/tls`.

Do not stack the two macOS variants: plain `brew install openshell` installs
the homebrew-core formula — a *different packaging* (no brew-service support,
PKI under `~/.config/openshell/tls`). Installing it before/over the official
installer leaves two PKIs and two gateway layouts behind; uninstall the other
one first (`brew uninstall openshell`) and re-register the gateway after
(`./demo/start-openshell-gateway.sh` does this).

**Linux (same official installer):**
```bash
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
```
Then restart your shell or run `source ~/.bashrc` (or `~/.zshrc`).

Verify:
```bash
openshell --version
```

### Starting the OpenShell gateway (macOS)

The gateway runs locally with the **Docker driver** and handles sandbox
creation and policy enforcement. With the official installer, the brew service
is the supported way to run it — `demo/start-openshell-gateway.sh` manages that
service (and only falls back to a manual spawn when no brew service exists).

**Two Docker Desktop quirks to know about:**

- Sandbox runners inside the Docker VM must be able to reach the gateway, so
  it must not be bound to loopback only (`--bind-address 0.0.0.0` when run
  manually). `demo/start-openshell-gateway.sh` checks the listener after
  start-up and warns when it finds a loopback-only bind.
- The Docker driver starts a *supervisor* container with host networking that
  calls back to `https://127.0.0.1:17670`. On Docker Desktop, "host" is the
  Linux VM, not your Mac, so that address is empty. You need a small port
  forwarder inside the VM — the script's `gw-fwd` container. Without it,
  `sandbox create` fails with
  `ControlSupervisorStartFailed ... failed to connect to OpenShell server`.

**Use the provided script (`demo/start-openshell-gateway.sh`):**

```bash
cd demo
chmod +x start-openshell-gateway.sh
./start-openshell-gateway.sh
```

The script:
1. Restarts the brew service (`sh.brew.openshell`) when it exists; otherwise it falls back to starting the gateway manually, bound to `0.0.0.0:17670` (waiting for any previous instance to fully exit first).
2. Waits until `https://127.0.0.1:17670` answers (instead of a blind sleep that crowded the registration).
3. Creates a `gw-fwd` container that forwards `127.0.0.1:17670` inside the Docker VM to your Mac's LAN IP.
4. Re-registers the CLI gateway as `openshell`, provisioning the registration's mTLS material from the *live* PKI dir (`OPENSHELL_LOCAL_TLS_DIR`) — this is what keeps a reinstall from leaving the CLI with a stale CA (`invalid peer certificate: BadSignature`).
5. Verifies connectivity (`openshell status` + expects HTTP 404 through the VM forwarder).

**How the forwarder target is chosen** (and how to recreate it by hand):
```bash
docker rm -f gw-fwd
docker run -d --name gw-fwd --restart unless-stopped --network host \
  alpine/socat TCP-LISTEN:17670,bind=127.0.0.1,fork,reuseaddr TCP:host.docker.internal:17670
```
The script does not hardcode an IP: from inside the Docker VM, `host.docker.internal` reaches the gateway across vpnkit **even when the gateway is bound to the Mac's loopback only** (a brew-managed gateway is), and it survives LAN-IP changes — so it is the preferred target. The script probes it from the VM first and only falls back to the Mac's LAN IP when `host.docker.internal` is unreachable; if neither works it fails loudly, because sandbox supervisors have no other path to the gateway.

The gateway runs on `https://127.0.0.1:17670` by default (the CLI connects to localhost). The `gw-fwd` container forwards `127.0.0.1:17670` inside the Docker VM to your Mac's LAN IP. Keep the service running while you use the sandbox: the brew-managed gateway starts at login, but on the manual-fallback path the gateway does not survive a reboot, so rerun the script after reboot.

**Tip:** The compute driver no longer needs to come from an environment
variable. `demo/openshell-gateway-setup.sh` pins it in the schema-v2 config
(`[openshell.gateway] compute_driver = "docker"` in `gateway.toml`); without
that pin, a service-managed gateway without the env var defaults to the podman
driver and `sandbox create` fails with a podman image-pull error such as
`"podman API error (500): image pull failed ... requested access to the
resource is denied"` (the image exists only in Docker Desktop, not on docker.io).

### Starting the OpenShell gateway (Linux)

On Linux the gateway can use either **Podman** (default if available) or **Docker** driver. If you're not using NemoClaw (which auto-configures the gateway via systemd), start it manually.

**Note:** The Docker driver ignores `OPENSHELL_GRPC_ENDPOINT`; the variable is
not needed. Use `OPENSHELL_COMPUTE_DRIVER` (the old `OPENSHELL_DRIVERS` is
deprecated and prints a warning).

**Use the provided script (`demo/start-openshell-gateway-linux.sh`):**

```bash
cd demo
chmod +x start-openshell-gateway-linux.sh
./start-openshell-gateway-linux.sh
```

The script:
1. Generates TLS certificates
2. Starts the gateway bound to `0.0.0.0:17670` with the chosen driver
3. Registers the gateway as `local-gateway`
4. Verifies connectivity (expects HTTP 404 on healthz)

**Difference from macOS:** On Linux you can use `OPENSHELL_COMPUTE_DRIVER=podman`
(default) or `docker`. On macOS use `docker` (Podman Desktop isn't part of
this demo's supported pairing); there the driver is pinned in `gateway.toml`
rather than passed through the environment.

**If using Docker Desktop on Linux**, the same port forwarder (macOS step 4)
is probably needed there; I haven't tested it.

**Tip:** Add `export OPENSHELL_COMPUTE_DRIVER=docker` (or `podman`) to your
`~/.bashrc` / `~/.zshrc` so it's always set.

### Getting an NVIDIA API key

The demo calls NVIDIA's hosted endpoint, so you need a free key from NVIDIA's
build site. The free hosted models here are the same ones NemoClaw's default
**"NVIDIA Endpoints"** option uses, so one key covers both.

1. Go to <https://build.nvidia.com/settings/api-keys> and sign in with an
   NVIDIA account (creating one is free).
2. Click **Generate API Key**, give it a name, pick an expiration, and hit
   **Generate Key**.
3. Copy the key — it starts with `nvapi-`.

Then put it in `demo/.env`:

```bash
echo 'NVIDIA_API_KEY=nvapi-...' >> demo/.env
```

Treat the key like a password: `demo/.env` is gitignored, so it never reaches
version control, and the sandbox only ever sees the *variable name* — the
secret itself stays on your machine and in your environment.

## Quick start

> Podman machine? The `make openclaw-*` targets build/pull images through
> `ENGINE=` which auto-detects a *reachable* engine (a quit-but-installed
> Docker Desktop is skipped); force with `ENGINE=podman make openclaw-demo`
> if detection ever hits a dead Docker socket. Compose boilerplate:
> `docker compose` below reads as `podman compose`.

```bash
# everything: build the image, create the sandbox, configure the provider, chat
make openclaw-demo
```

Expected result — a reply from the agent:

```text
  ✓ sandbox 'openclaw' is up (OpenClaw gateway on :18789 inside the sandbox)
  ✓ provider configured: https://integrate.api.nvidia.com/v1 (model: nvidia/nemotron-3-super-120b-a12b)

Chat with OpenClaw (inside the sandbox)
I am your new assistant. What would you like to call me?
```

Or run the steps individually:

```bash
make openclaw-image       # build the image
make openclaw-up          # create the sandbox, start the gateway
make openclaw-configure   # provider + egress allowlist
make openclaw-chat MSG="hello"
make openclaw-status      # sandbox + gateway health
make openclaw-shell       # interactive shell inside the sandbox
make openclaw-down        # delete the sandbox
```

The same commands work directly: `./demo/openclaw-sandbox.sh <command>`.

## What each step does

**Image** (`demo/openclaw/Dockerfile`) — Ubuntu 24.04 + Node 22 + OpenClaw,
installed globally. A non-root `sandbox` user (uid 1001) owns a writable
`/sandbox`. A minimal OpenClaw config is baked in with the provider defined
and the API key as an **env SecretRef** — only the variable *name* is in the
image, never the secret. OpenShell requires no `ENTRYPOINT`/`CMD` here; it
injects its own supervisor.

**Sandbox create** — the start command is `openclaw gateway run --bind
loopback --allow-unconfigured`. Three flags in that line are load-bearing:

- `--allow-unconfigured` — without it the gateway refuses to boot against the
  minimal baked config and exits 78.
- `SQLITE_TMPDIR=/tmp` (passed as `--env`) — the gateway runs under OpenShell's
  Landlock filesystem sandbox, and SQLite needs a writable temp dir to create
  the FTS5 shadow tables for the agent transcript DB. Skip it and the first
  chat turn dies with `fts5: … unable to open database file`.
- `PROVIDER_API_KEY` (passed as `--env`) — the *gateway* process makes the
  model call, so it is the one that must resolve the SecretRef.

`sandbox create` is deliberately **not** given `--forward`: that flag holds the
foreground command attached to an SSH tunnel, so it never returns. Every later
command reaches the sandbox with `openshell sandbox exec`, which needs no
host port-forward.

**Configure** — writes `openclaw.json` inside the sandbox and applies the
egress allowlist. The model `id` stored in the config is the **bare** id
(`nemotron-3-super-120b-a12b`); OpenClaw prefixes the provider key (`nvidia`)
onto it when building the API request, so a prefixed id would send
`nvidia/nvidia/…` and the API would reject it.

**Egress** — the sandbox is default-deny. `configure` allows exactly the model
provider plus the OpenClaw catalog hosts, for the binaries that need them. The
allowlist endpoint is written as `host:443` with **no `::tcp` suffix**: the
sandbox routes egress through OpenShell's HTTP proxy (`HTTPS_PROXY` is
pre-set inside the sandbox), which is already running. Adding `::tcp` demands
the *transparent TCP* substrate, which must be enabled when the sandbox is
created, and the update fails atomically with `previous policy remains active`.

You can watch the policy work in the logs:

```bash
openshell logs openclaw | grep -E 'ALLOWED|DENIED'
```

```text
OCSF NET:OPEN [INFO] ALLOWED /usr/bin/node(269) -> integrate.api.nvidia.com:443 [policy:openclaw_egress engine:opa]
OCSF HTTP:POST [INFO] ALLOWED POST http://integrate.api.nvidia.com:443/v1/chat/completions
```

Anything not on the allowlist — telemetry, an arbitrary host — is denied
without reaching the network.

## Choosing a model

The demo default is `nvidia/nemotron-3.5-lightning-30b-a3b` — the fastest
*nvidia/-front* model verified callable on the free NVIDIA key
(~0.7 s time-to-first-token direct; **6 s OpenClaw turns** vs ~90 s on the
reasoning-heavy `nvidia/nemotron-3-super-120b-a12b`, whose thinking phase
dominated each turn). Not every model listed by
`/v1/models` is callable on a given key: some return `404 … Not found for
account` (not enabled for that key), and it can also answer `503` during a
capacity lull — the same key can succeed again minutes later.

If chat fails or turns drag, check the model directly from the host before
blaming the sandbox:

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 30 \
  -H "Authorization: Bearer $NVIDIA_API_KEY" -H 'Content-Type: application/json' \
  https://integrate.api.nvidia.com/v1/chat/completions \
  -d '{"model":"nvidia/nemotron-3.5-lightning-30b-a3b","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'
```

`200` means the model is fine — then any failure is on the sandbox side.
Override the model with `PROVIDER_MODEL=<model-id> make openclaw-demo`; ids may
carry their catalog namespace (`meta/llama-3.2-11b-vision-instruct`) — anything
with a `/` is used verbatim, bare ids get the `nvidia/` provider prefix.

## Platform notes

On macOS (Docker Desktop) a port forwarder is required, see
**Starting the OpenShell gateway (macOS)**. Verified on Debian 13 (x86_64) and
macOS with Docker Desktop.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Console sign-in fails with `Bad Request — Unregistered redirect_uri` | this machine's URI is not in dex's allow-list. Run `./demo/refresh-dex-redirects.sh` (adds the machine's LAN IPv4s + recreates dex; bring-up paths run it automatically). From a *foreign* device only: `DEX_EXTRA_IPS="<that ip>" ./demo/refresh-dex-redirects.sh`. On k3s edit the `dex-config` ConfigMap in [`k3s/agentgw.yaml`](../k3s/agentgw.yaml). |
| `sandbox create` returns immediately, sandbox phase `Error` | the gateway exited — run `openshell logs <name>`; usually a missing `--allow-unconfigured` |
| `fts5: error creating shadow table … unable to open database file` | `SQLITE_TMPDIR=/tmp` is missing from the create `--env` list |
| `Secret owner provider:… is unavailable` | `PROVIDER_API_KEY` is not in the gateway process env — recreate via `make openclaw-up` with `demo/.env` present |
| `candidate policy introduces protocol: tcp` | the egress rule used a `::tcp` suffix — use `host:443` |
| `LLM request failed: network connection error` | egress allowlist missing the provider host — rerun `make openclaw-configure` |
| `HTTP 410` / `404 … Not found for account` | the model is EOL or not enabled on your key (see *Choosing a model*) |
| `gateway not answering on :18789 yet` | wait a few seconds and rerun `make openclaw-status` |
| Chat returns `reasoning-only retries exhausted` or `provider=nvidia/nvidia/…` | stale session with a double-prefixed model id — `make openclaw-restart` (deletes the sandbox and recreates it cleanly) |
| `ControlSupervisorStartFailed ... failed to connect to OpenShell server` | The supervisor can't reach the gateway at 127.0.0.1:17670 inside the Docker VM. Create the `gw-fwd` forwarder (macOS step 4). |
| `openshell status: Connection reset by peer`, and gateway.log shows `Rejected plaintext HTTP` | The gateway registration is http:// / plaintext (check `~/.config/openshell/gateways/<name>/metadata.json`). Run `openshell gateway remove <name>`, then `openshell gateway add --local https://127.0.0.1:17670 --name <name>`. |
| `pkill openshell-gateway` doesn't stop it | macOS truncates process names. Use `pkill -f openshell-gateway`. |
| `OPENSHELL_DRIVERS` is deprecated | Use `OPENSHELL_COMPUTE_DRIVER`. |

## Advanced: routing the sandbox's egress through the Agent Gateway proxy

> **OpenShell version note:** the upstream-proxy wiring below needs OpenShell **0.1.x** with the
> schema-**v2** gateway config (schema v1 in 0.0.x rejects the proxy keys outright —
> `unknown field https_proxy`). The demo was brought up on 0.1.4 + Docker CE 29.9.1; the moby
> `getent 1001:1001` bug in older engines (26.x) also breaks `sandbox create` under the 0.1.x
> docker driver — see the engine note at the end.

By default the sandbox's egress is governed by OpenShell's own proxy enforcement (default-deny
allowlist installed by `openclaw-sandbox.sh configure`). When you want *every* outbound call to go
through the Agent Gateway's egress proxy (so each destination becomes one authorization decision
per call), you can layer the Agent Gateway on top using OpenShell's **upstream proxy** feature:

```
agent (in sandbox) → OpenShell supervisor (policy check) → CONNECT host:443 → Agent Gateway
                                                          (approval hold)    → destination
```

The OpenShell supervisor opens one top-level `CONNECT` per destination and chains it through the
Agent Gateway. Nothing extra runs inside the sandbox — no local proxy process, no `HTTP_PROXY`
tweaks — and OpenShell keeps enforcing its default-deny sandbox policy *before* consulting the
gateway, so the two layers compose cleanly: OpenShell decides *whether traffic may reach* the
gateway; the gateway decides *whether the request may proceed*, holding risky actions for a human.

The steps are:

1. **Start the Agent Gateway stack with the egress overlay** (from `demo/`):
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.egress.yml up -d
   ```
   This publishes:
   - PEP gateway on `:9000` (or `:8080` if `GATEWAY_HOST_PORT` is unset)
   - Egress forward proxy on `:8088`
   - Authz on `:8081`, TokenSvc on `:8082`, Web console on `:8083`

2. **Configure OpenShell to use the Agent Gateway as its upstream proxy** in the OpenShell
   gateway config (`~/.config/openshell/gateway.toml`, under the `[openshell.drivers.docker]`
   section — that is the driver section this demo uses). Schema v2 renames the 0.0.x layout
   (`version = 2`, `compute_driver`, [`openshell.gateway`]-level `guest_tls_ca`; drop
   `sandbox_namespace`, `network_name`, `guest_tls_cert`/`guest_tls_key`, and `ttl_secs = 0` —
   v2 needs a nonzero value):

   ```toml
   [openshell]
   version = 2

   [openshell.gateway]
   compute_driver = "docker"
   guest_tls_ca = "/home/YOU/.config/openshell/tls/ca.crt"

   [openshell.drivers.docker]
   grpc_endpoint = "https://127.0.0.1:17670"
   supervisor_image = "ghcr.io/nvidia/openshell/supervisor:0.1.4"
   supervisor_bin = "/home/YOU/.local/bin/openshell-sandbox"

   # The Agent Gateway egress proxy becomes the upstream "corporate proxy":
   https_proxy = "http://127.0.0.1:8088"
   proxy_auth_file = "/home/YOU/.config/openshell/upstream-proxy-auth"
   proxy_auth_allow_insecure = true   # acknowledges cleartext Basic over http:// loopback
   proxy_connect_by_hostname = true   # keep the destination hostname as the resource
   ```

   Then restart the OpenShell gateway so the new config takes effect
   — on a NemoClaw-managed box: restart the `openshell-gateway` process (the
   active config path is shown in its `OPENSHELL_GATEWAY_CONFIG` environment);
   on macOS with the official tap: `brew services restart
   nvidia/openshell/openshell`; or rerun `./demo/start-openshell-gateway.sh`,
   which handles both. (`demo/openshell-gateway-setup.sh` shows the right
   command for the current install whenever it patches `gateway.toml`.)

3. **Create a delegation for the NVIDIA model host** (via mock SSO):

   The delegation grants the agent access to `integrate.api.nvidia.com:443`
   and returns an `agent_secret` (used to mint short-lived tokens via TokenSvc).

4. **Mint a short-lived token** from the `agent_secret` (valid 30 min) and write it to the
   upstream proxy auth file as OpenShell expects it (token as Basic **username**):

   ```bash
   TOKEN=$(curl -s -X POST http://localhost:8082/token \
     -H "Content-Type: application/json" \
     -d '{"delegation_id":"...","ttl_seconds":1800,"agent_secret":"..."}' \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')
   printf '%s:x\n' "$TOKEN" > ~/.config/openshell/upstream-proxy-auth
   chmod 600 ~/.config/openshell/upstream-proxy-auth
   ```

   The 0.1.x docker driver copies that file into the supervisor's volume **at sandbox start**,
   so a rotated token needs one `openshell sandbox stop <name> && openshell sandbox start <name>`
   (the workspace survives; the OpenClaw gateway inside restarts, and
   `demo/openclaw-egress-test.sh` performs the stop/start itself when it refreshes credentials).

5. **Point the agent at its destination — not at the proxy.** The sandbox policy allowlists the
   *destination* (e.g. `integrate.api.nvidia.com:443::tcp` for the model binaries); the Agent
   Gateway proxy is never named in the sandbox policy. OpenShell forwards the staged connection
   transparently through the upstream proxy configured on the gateway, and the destination
   hostname survives as the authorization resource the gateway evaluates.

### Why Basic auth — and how it is kept safe

Two credential schemes can reach the egress proxy (`Proxy-Authorization`):

- **Bearer** — `Proxy-Authorization: Bearer <token>`, the default scheme for explicit proxy
  clients (curl, the Go helper). Always accepted at any source address.
- **Basic** — `Proxy-Authorization: Basic base64(<token>:x)`, the only scheme OpenShell's
  upstream proxy can produce: its `proxy_auth_file` holds a static `token:pass` line and is sent
  with every chained connection.

Basic is therefore **explicitly enabled and tightly scoped** (in the
`docker-compose.egress.yml` overlay, or as plain env on the gateway):

```bash
PROXY_BASIC_AUTH=1                            # enable the scheme (default: off)
PROXY_BASIC_AUTH_CIDRS=127.0.0.0/8,::1/128,172.21.0.0/16   # peers allowed to use it
```

What those settings mean in practice:

- With `PROXY_BASIC_AUTH` unset (or `0`), a Basic credential answers **407** even with a valid
  token — Bearer keeps working. Basic is an explicitly opted-in compatibility surface, never a
  silent second path.
- `PROXY_BASIC_AUTH_CIDRS` pins *who* may authenticate with Basic: a Basic request from a source
  IP outside these networks answers 407 **before the token is even resolved**. Bearer callers are
  unaffected by the CIDR list.
- The owner's connections arrive via Docker's userland proxy and surface at the gateway
  container as its *compose network's* gateway IP (e.g. `172.26.0.1` for the stack's
  `demo_default` network) — not `127.0.0.1`. The demo overlay therefore defaults the CIDR list
  to loopback **plus the RFC1918 block Docker compose networks live in**
  (`127.0.0.0/8,::1/128,172.16.0.0/12`). Narrow it to the exact /24 when you know it; never
  widen it to `0.0.0.0/0`.
- `proxy_auth_allow_insecure = true` on the OpenShell side acknowledges that this one hop sends
  the credential as cleartext Basic over plain HTTP. On a same-host demo that is the trade-off;
  for a remote gateway put it behind TLS and drop the flag.

Note that a *rotating* token (re-mint after expiry, as `agent-gateway` requires for long
sessions) means re-writing `proxy_auth_file` plus one
`openshell sandbox stop <name> && openshell sandbox start <name>` — the docker driver copies the
credential into the supervisor volume at start, so no gateway restart is needed.

### Platform notes (macOS)

On Apple Silicon the same flow works with three Mac deltas:

- **AGW runs in a container.** The stack is the same `docker compose ... up -d` (the images are
  multi-arch, so 1.0.24 runs natively), and its egress proxy is reachable from the VM only via
  `host.docker.internal`. Consequently the OpenShell gateway config uses
  `https_proxy = "http://host.docker.internal:8088"` instead of `127.0.0.1`.
- **The source IP the gateway sees is Docker Desktop's bridge, not localhost.** Set the CIDR
  list in `demo/.env` before `docker compose ... up -d`:
  ```bash
  echo 'PROXY_BASIC_AUTH_CIDRS=127.0.0.0/8,::1/128,192.168.65.0/24,172.16.0.0/12' >> demo/.env
  ```
  (`192.168.65.0/24` is Docker Desktop's host-gateway block; widen to `192.168.0.0/16` if your
  compose network lands there. If the Basic request still answers `not permitted from <ip>`,
  the IP in that message is exactly the address to allow.)
- **Credentials live on the Mac's home**, so `proxy_auth_file` points at the macOS
  `~/.config/openshell/upstream-proxy-auth`, the Docker driver is pinned to via
  `[openshell.gateway] compute_driver = "docker"` in `gateway.toml`, and the
  gateway runs through the brew service (`brew services restart
  nvidia/openshell/openshell` — or just `./demo/start-openshell-gateway.sh`).

**Package variants, PKI, and config hygiene (macOS).** A 2026-10 incident on
one machine combined all three, so the specifics are worth writing down:

- There are two macOS package variants: the homebrew-core formula (no brew
  service, PKI in `~/.config/openshell/tls`) and the official `install.sh` tap
  `nvidia/openshell` (brew service, PKI in `/opt/homebrew/var/openshell/tls`).
  Version numbers can be identical while the layouts are not. If you switch,
  uninstall the other variant first and you will not inherit a mixed PKI.
- The CLI caches each registration's CA + client certs under
  `~/.config/openshell/gateways/<name>/mtls/` at `gateway add` time,
  provisioning from `OPENSHELL_LOCAL_TLS_DIR` (default `~/.config/openshell/tls`).
  After a gateway reinstall/PKI regeneration, `openshell status` reports
  `invalid peer certificate: BadSignature` — and re-adding with the *old local
  TLS dir* keeps it broken. Fix: point `OPENSHELL_LOCAL_TLS_DIR` at the live
  PKI and remove + re-add (`./demo/start-openshell-gateway.sh` does exactly
  this), or refresh the `mtls/` dir from the live PKI by hand.
- A duplicate `[openshell.drivers.<driver>]` table in `gateway.toml` is fatal
  for boot (TOML: `duplicate key '<driver>' in table 'openshell.drivers'`), and
  the gateway then looks dead (`Connection refused` on 17670) with no runtime
  symptom other than the service's `.err.log`. The gateway brew logs live in
  `/opt/homebrew/var/log/openshell/openshell-gateway.{out,err}.log`.
  `demo/openshell-gateway-setup.sh` now runs its config patch through
  `demo/patch-driver-config.py`, which repairs duplicates, is idempotent, and
  refuses to write anything that does not parse.

### Approval holds and draining them

When the gateway's decision says `RequireApproval` (e.g. every `connect` under the all-egress
rule), the proxied call gets a **202 approval_required** and the human decides — via the web
console, the admin API, or Telegram (the demo's default channel).

Approval binding is exact: (delegation, destination host, action), and **single-use** — the next
matches a fresh hold. For the demo's automated flow, `demo/egress-demo.sh` walks the entire loop
using `example.com` as the target host; the guided egress test
(`make openclaw-egress-test GW=--gateway`) walks the same loop against the real NVIDIA host,
with the agent's dialogue shown and an undelegated-host denial. Each of the first two holds opens a
60 s human window — the script polls the approvals list every few seconds, so approving the live
Telegram card or the web console continues the run immediately; if no one decides within the window
the script auto-approves. For unattended or CI runs, pass `--no-human`
(`GW="--gateway --no-human" make openclaw-egress-test`) to auto-approve every hold immediately.

For production use, replace the mock Dex connector with your real OIDC
provider and use the web console (`http://localhost:8083`) or the approval
API to authorize each destination.

## Known limitations

**Expired approvals remain visible in the web console** — Approvals that
have passed their `expires_at` timestamp are still shown in the web UI
with "Approve"/"Deny" buttons, but clicking them returns `approval expired`.
The web console (`agent-gateway-web`) currently doesn't filter by
`expires_at`. Workaround: delete the originating delegation (which
removes future approvals) and ignore expired entries in the UI.

```bash
# Delete old delegations to prevent new expired approvals
curl -X DELETE http://localhost:8081/v1/delegations/<delegation_id> \
  -H "X-Admin-Token: agent-gateway-demo-admin"
```

A proper fix would add an `expires_at` filter to the web console's
approval listing or a TTL-based cleanup job in the gateway/authz.

**`/proc/self/oom_score_adj: Permission denied` in agent exec output** —
when OpenClaw narrates an exec tool call, it sometimes surfaces lines like
`/bin/bash: 1: cannot create /proc/self/oom_score_adj: Permission denied`.
This is OpenShell's sandbox design working as intended: the sandbox user is
unprivileged and the kernel only lets a process lower its OOM vulnerability
with privileges, so an OOM-tuning attempt by in-sandbox startup tooling fails
harmlessly. The command itself still runs and exits normally (reproduced on
Linux and macOS with openshell 0.1.4; `openclaw-egress-test.sh` parses the
real HTTP output around it and checks pass). Cosmetic — no action needed.

## Next: govern the sandbox's egress

This demo proves the isolation boundary and a working model call. The next
step is routing *every* outbound call through the Agent Gateway's egress
proxy so destination host becomes one authorization decision per call — see
[Local-Agents.md §Shape 2½](Local-Agents.md) and
[openshell-gateway-setup.sh](../demo/openshell-gateway-setup.sh).
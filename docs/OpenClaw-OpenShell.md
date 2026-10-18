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
| Docker | `docker version` |
| OpenShell CLI | `openshell --version` — see install below |
| An NVIDIA API key | in `demo/.env` as `NVIDIA_API_KEY=nvapi-…` |

The key is read from `demo/.env` (gitignored). You can also export
`NVIDIA_API_KEY` directly, or point at any OpenAI-compatible endpoint with
`PROVIDER_BASE_URL` / `PROVIDER_MODEL`.

### Installing OpenShell

**macOS (Homebrew):**
```bash
brew install openshell
```

**Linux (official installer):**
```bash
curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
```
Then restart your shell or run `source ~/.bashrc` (or `~/.zshrc`).

Verify:
```bash
openshell --version
```

### Starting the OpenShell gateway (macOS)

On macOS you must run the gateway locally with the **Docker driver** (Podman isn't available on macOS). The gateway handles sandbox creation and policy enforcement.

**Two Docker Desktop quirks to know about:**

- The gateway must bind `0.0.0.0` so it is reachable from outside localhost.
- The Docker driver starts a *supervisor* container with host networking that
  calls back to `https://127.0.0.1:17670`. On Docker Desktop, "host" is the
  Linux VM, not your Mac, so that address is empty. You need a small port
  forwarder inside the VM (step 4). Without it, `sandbox create` fails with
  `ControlSupervisorStartFailed ... failed to connect to OpenShell server`.

**Use the provided script (`demo/start-openshell-gateway.sh`):**

```bash
cd demo
chmod +x start-openshell-gateway.sh
./start-openshell-gateway.sh
```

The script:
1. Generates TLS certificates
2. Starts the gateway bound to `0.0.0.0:17670`
3. Creates a `gw-fwd` container that forwards `127.0.0.1:17670` inside the Docker VM to your Mac's LAN IP
4. Registers the gateway as `mac-gateway`
5. Verifies connectivity (expects HTTP 404 on healthz)

**If your LAN IP changes**, recreate the forwarder:
```bash
docker rm -f gw-fwd
docker run -d --name gw-fwd --restart unless-stopped --network host \
  alpine/socat TCP-LISTEN:17670,bind=127.0.0.1,fork,reuseaddr TCP:$(ipconfig getifaddr en0):17670
```

The gateway runs on `https://127.0.0.1:17670` by default (the CLI connects to localhost). The `--bind-address 0.0.0.0` makes it reachable from the Docker Desktop VM. The `gw-fwd` container forwards `127.0.0.1:17670` inside the Docker VM to your Mac's LAN IP. Keep the gateway process running while you use the sandbox. The `gw-fwd` container restarts with Docker, but the gateway does not survive a reboot, so rerun the script after reboot.

**Tip:** Add `export OPENSHELL_COMPUTE_DRIVER=docker` to your shell profile (`~/.zshrc` or `~/.bash_profile`) so it's always set.

**Tip:** Add `export OPENSHELL_COMPUTE_DRIVER=docker` to your shell profile
(`~/.zshrc` or `~/.bash_profile`) so it's always set.

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
(default) or `docker`. On macOS you **must** use `docker` since Podman isn't
available.

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

The default is `nvidia/nemotron-3-super-120b-a12b`. Not every model listed by
`/v1/models` is callable on a given key: some return `410` (end of life) or a
`404 … Not found for account` (not enabled for that key). If chat fails, check
the model directly from the host before blaming the sandbox:

```bash
curl -s -o /dev/null -w '%{http_code}\n' --max-time 30 \
  -H "Authorization: Bearer $NVIDIA_API_KEY" -H 'Content-Type: application/json' \
  https://integrate.api.nvidia.com/v1/chat/completions \
  -d '{"model":"nvidia/nemotron-3-super-120b-a12b","messages":[{"role":"user","content":"hi"}],"max_tokens":8}'
```

`200` means the model is fine — then any failure is on the sandbox side.
Override the model with `PROVIDER_MODEL=<bare-id> make openclaw-demo`.

## Platform notes

On macOS (Docker Desktop) a port forwarder is required, see
**Starting the OpenShell gateway (macOS)**. Verified on Debian 13 (x86_64) and
macOS with Docker Desktop.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `sandbox create` returns immediately, sandbox phase `Error` | the gateway exited — run `openshell logs <name>`; usually a missing `--allow-unconfigured` |
| `fts5: error creating shadow table … unable to open database file` | `SQLITE_TMPDIR=/tmp` is missing from the create `--env` list |
| `Secret owner provider:… is unavailable` | `PROVIDER_API_KEY` is not in the gateway process env — recreate via `make openclaw-up` with `demo/.env` present |
| `candidate policy introduces protocol: tcp` | the egress rule used a `::tcp` suffix — use `host:443` |
| `LLM request failed: network connection error` | egress allowlist missing the provider host — rerun `make openclaw-configure` |
| `HTTP 410` / `404 … Not found for account` | the model is EOL or not enabled on your key (see *Choosing a model*) |
| `gateway not answering on :18789 yet` | wait a few seconds and rerun `make openclaw-status` |
| `ControlSupervisorStartFailed ... failed to connect to OpenShell server` | The supervisor can't reach the gateway at 127.0.0.1:17670 inside the Docker VM. Create the `gw-fwd` forwarder (macOS step 4). |
| `openshell status: Connection reset by peer`, and gateway.log shows `Rejected plaintext HTTP` | The gateway registration is http:// / plaintext (check `~/.config/openshell/gateways/<name>/metadata.json`). Run `openshell gateway remove <name>`, then `openshell gateway add --local https://127.0.0.1:17670 --name <name>`. |
| `pkill openshell-gateway` doesn't stop it | macOS truncates process names. Use `pkill -f openshell-gateway`. |
| `OPENSHELL_DRIVERS` is deprecated | Use `OPENSHELL_COMPUTE_DRIVER`. |

## Advanced: routing the sandbox's egress through the Agent Gateway proxy

By default the sandbox uses OpenShell's built-in HTTP proxy (`HTTPS_PROXY=http://10.200.0.1:3128`),
which enforces the default-deny policy locally. If you want *every* outbound call to go through
the Agent Gateway's egress proxy (so each destination becomes one authorization decision per call),
you can layer the Agent Gateway on top. The steps are:

1. **Start the Agent Gateway stack** (from `demo/`):
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.egress.yml up -d
   ```
   This publishes:
   - PEP gateway on `:9000` (or `:8080` if `GATEWAY_HOST_PORT` is unset)
   - Egress forward proxy on `:8088`
   - Authz on `:8081`, TokenSvc on `:8082`, Web console on `:8083`

2. **Set the console URL for Telegram notifications** (required for approval buttons):
   ```bash
   # Replace with your machine's LAN IP or a public tunnel URL
   export DEMO_CONSOLE_URL=http://192.168.1.53:8083
   # Or add to demo/.env:
   echo 'DEMO_CONSOLE_URL=http://YOUR_LAN_IP:8083' >> demo/.env
   docker compose -f docker-compose.yml -f docker-compose.egress.yml up -d
   ```
   Without this, Telegram rejects the approval card's "Open the console" button
   (it blocks `localhost` URLs in inline keyboards).

3. **Create a delegation for the NVIDIA model host** (via mock SSO):
   ```bash
   # The demo stack includes a Dex mock connector for easy testing.
   # You can script this or use `demo/egress-demo.sh` which automates the full flow.
   ```
   The delegation grants the agent access to `integrate.api.nvidia.com:443`
   and returns an `agent_secret` (used to mint short-lived tokens via TokenSvc).

   **Approval rule examples:**
   - *Auto-allow NVIDIA model calls* (connect + read):
     ```json
     {
       "resources": ["integrate.api.nvidia.com"],
       "actions": ["read", "connect", "create", "delete"],
       "approval_rules": [
         {"when": {"action_pattern": "create", "resource_pattern": "*"}, "require": true, "rationale": "POST/create require approval"},
         {"when": {"action_pattern": "delete", "resource_pattern": "*"}, "require": true, "rationale": "DELETE require approval"}
       ]
     }
     ```
     This allows GET + CONNECT (model calls) automatically, only holding POST/DELETE.

   - *Require approval for all outbound* (OpenShell-style):
     ```json
     "approval_rules": [
       {"when": {"action_pattern": "connect", "resource_pattern": "*"}, "require": true},
       {"when": {"action_pattern": "create", "resource_pattern": "*"}, "require": true}
     ]
     ```

3. **Mint a short-lived token** from the `agent_secret` (valid 30 min):
   ```bash
   curl -X POST http://localhost:8082/token \
     -H "Content-Type: application/json" \
     -d '{"delegation_id":"...","ttl_seconds":1800,"agent_secret":"..."}'
   ```

4. **Run a local CONNECT proxy inside the sandbox** that adds the Bearer token
   and forwards to the Agent Gateway proxy at `http://172.21.0.1:8088`
   (the Docker network gateway IP visible from inside the sandbox).
   
   A pre-built `connect-proxy` binary is included in the repo at
   `demo/connect-proxy` (or build it from `demo/connect-proxy.go` with `go build`).

   ```bash
   ./demo/connect-proxy "http://172.21.0.1:8088" "<agent_token>" &
   ```

4. **Configure OpenClaw to use the local proxy**:
   ```bash
   HTTPS_PROXY=http://127.0.0.1:8888 NODE_USE_ENV_PROXY=1 openclaw agent -m "hello"
   ```

The `demo/egress-demo.sh` script demonstrates the full automated flow
(SSO sign-in → delegation → agent token → proxied requests) against the
running stack, using `example.com` as the target host. Adapt it for
`integrate.api.nvidia.com` by changing the delegation's `resources` field.

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

## Next: govern the sandbox's egress

This demo proves the isolation boundary and a working model call. The next
step is routing *every* outbound call through the Agent Gateway's egress
proxy so destination host becomes one authorization decision per call — see
[Local-Agents.md §Shape 2½](Local-Agents.md) and
[openshell-gateway-setup.sh](../demo/openshell-gateway-setup.sh).
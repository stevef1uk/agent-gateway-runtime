#!/usr/bin/env bash
# OpenShell + Agent Gateway local setup helper
#
# Verified against OpenShell 0.1.4 with the DOCKER compute driver and the
# schema-v2 gateway config. What it does:
#   - verify the demo's Agent Gateway stack is up
#   - PATCH the OpenShell gateway config (~/.config/openshell/gateway.toml)
#     with the upstream-proxy stanza that chains every policy-approved tunnel
#     through the Agent Gateway egress proxy. Existing TLS/mTLS/JWT settings
#     are preserved — the script edits only the driver block. You still have
#     to restart the OpenShell gateway yourself (it is not supervised here).
#   - register the local OpenShell gateway
#   - create a delegation allowing ordinary provider API calls while keeping
#     CONNECT and DELETE under the gateway approval policy
#   - mint the delegation token and write it to
#     ~/.config/openshell/upstream-proxy-auth (token as Basic username) — the
#     0.1.x docker driver copies this file into the supervisor volume at
#     sandbox START, so existing running sandboxes get stop+started here to
#     pick it up.
#   - update the live sandbox policy so it can only reach the endpoints needed
#     for provider traffic, OpenClaw metadata refresh, and GitHub update checks;
#     the gateway remains the real decision point for risky actions.
#
# Usage:
#   ./demo/openshell-gateway-setup.sh
#   ./demo/openshell-gateway-setup.sh --check
#   ID_TOKEN=... ./demo/openshell-gateway-setup.sh
#   DEX_USER=alice DEX_PASSWORD=password ./demo/openshell-gateway-setup.sh
#
# Notes:
#   - requires OpenShell >= 0.1.x (schema v2). A v1 config (OpenShell 0.0.x)
#     is reported and left untouched — migrate it per
#     docs/OpenClaw-OpenShell.md ("Advanced" section) first.
#   - the sandbox policy accepts DNS hostnames; wildcards like "*.openrouter.ai"
#     are valid in the gateway delegation, but not in OpenShell's network policy
#     syntax. Use exact hosts there.
#   - the proxy itself (127.0.0.1:8088 / localhost:8088) is never added to the
#     sandbox allowlist; the OpenShell gateway config is what forwards the
#     request upstream.
#   - we explicitly allow the OpenClaw catalog and GitHub update endpoints here,
#     because OpenClaw probes them during model/provider discovery and update
#     checks. This is still a narrow allowlist, not a blanket outbound permit.

set -euo pipefail

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
  shift
fi

PROXY_URL="${PROXY_URL:-}"
# Mac (Darwin): the Agent Gateway runs in a container, so the supervisor's
# upstream dial goes through Docker Desktop's host-gateway alias.
if [ -z "$PROXY_URL" ]; then
  case "$(uname -s)" in
    Darwin) PROXY_URL="http://host.docker.internal:8088" ;;
    *)      PROXY_URL="http://127.0.0.1:8088" ;;
  esac
fi
GATEWAY_URL="${GATEWAY_URL:-https://127.0.0.1:17670}"
AUTHZ_URL="${AUTHZ_URL:-http://127.0.0.1:8081}"
TOKENSVC_URL="${TOKENSVC_URL:-http://127.0.0.1:8082/token}"
DEX_URL="${DEX_URL:-http://127.0.0.1:5556}"
DEX_USER="${DEX_USER:-alice}"
DEX_PASSWORD="${DEX_PASSWORD:-password}"
SANDBOX_NAME="${SANDBOX_NAME:-openclaw}"
OPENSSH_CONFIG_DIR="${HOME}/.config/openshell"

have() { command -v "$1" >/dev/null 2>&1; }

info() { printf '\n== %s ==\n' "$*"; }

apply_openrouter_policy() {
  local sandbox_name="$1"

  info "Updating the sandbox network policy for the allowed outbound set"

  # Start from a clean rule name so the allowlist does not accumulate stale
  # endpoints from prior runs. The sandbox remains default-deny; the gateway is
  # still the real decision point for risky outbound behavior.
  #
  # No `::tcp` suffix on any endpoint here (same as demo/openclaw-sandbox.sh's
  # openclaw_egress rule): the sandbox routes egress through OpenShell's HTTP
  # proxy (HTTPS_PROXY is pre-set), which does not register as the transparent
  # TCP substrate — and an endpoint shared with openclaw_egress in a different
  # substrate makes OpenShell's overlap validation reject the whole update
  # ("overlap on port(s) 443 with conflicting metadata").
  openshell policy update "$sandbox_name" --remove-rule openrouter_egress >/dev/null 2>&1 || true

  # Normal model/provider traffic.
  openshell policy update "$sandbox_name" \
    --rule-name openrouter_egress \
    --binary /usr/bin/bash \
    --binary /usr/local/bin/node \
    --binary /usr/bin/curl \
    --binary /usr/bin/wget \
    --binary /usr/local/bin/openclaw \
    --add-endpoint 'api.openrouter.ai:443' \
    --wait

  openshell policy update "$sandbox_name" \
    --rule-name openrouter_egress \
    --binary /usr/bin/bash \
    --binary /usr/local/bin/node \
    --binary /usr/bin/curl \
    --binary /usr/bin/wget \
    --binary /usr/local/bin/openclaw \
    --add-endpoint 'openrouter.ai:443' \
    --wait

  # OpenClaw metadata discovery / plugin catalog / release checks.
  openshell policy update "$sandbox_name" \
    --rule-name openrouter_egress \
    --binary /usr/bin/bash \
    --binary /usr/local/bin/node \
    --binary /usr/bin/curl \
    --binary /usr/bin/wget \
    --binary /usr/local/bin/openclaw \
    --add-endpoint 'catalog.openclaw.ai:443' \
    --wait

  openshell policy update "$sandbox_name" \
    --rule-name openrouter_egress \
    --binary /usr/bin/bash \
    --binary /usr/local/bin/node \
    --binary /usr/bin/curl \
    --binary /usr/bin/wget \
    --binary /usr/local/bin/openclaw \
    --add-endpoint 'clawhub.ai:443' \
    --wait

  openshell policy update "$sandbox_name" \
    --rule-name openrouter_egress \
    --binary /usr/bin/bash \
    --binary /usr/local/bin/node \
    --binary /usr/bin/curl \
    --binary /usr/bin/wget \
    --binary /usr/local/bin/openclaw \
    --add-endpoint 'api.github.com:443' \
    --wait
}

if ! have openshell; then
  echo "openshell CLI is not on PATH. Install it first." >&2
  exit 1
fi

if ! curl -fsS "$AUTHZ_URL/healthz" >/dev/null 2>&1; then
  echo "Agent Gateway authz service is not reachable at $AUTHZ_URL" >&2
  echo "Start the demo stack first: cd demo && docker compose up -d" >&2
  exit 1
fi

mkdir -p "$OPENSSH_CONFIG_DIR"

GW_TOML="$OPENSSH_CONFIG_DIR/gateway.toml"

if [ "$CHECK_ONLY" -eq 1 ]; then
  info "--check: reporting current state only (no writes)"
  if [ ! -f "$GW_TOML" ]; then
    echo "  ✗ $GW_TOML missing"
    exit 0
  fi
  DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  rc=0
  python3 "$DEMO_DIR/patch-driver-config.py" --check "$GW_TOML" || rc=$?
  exit "$rc"
fi

# ---------------------------------------------------------------------------
# Patch the OpenShell gateway config with the upstream-proxy stanza WITHOUT
# clobbering the rest (TLS, mTLS, JWT, credential config stay as they are).
# The patcher (demo/patch-driver-config.py) is idempotent, backs out duplicated
# driver tables it finds (TOML rejects those — the gateway refuses to boot
# with "duplicate key" errors), pins the schema-v2 compute driver to Docker,
# validates the result with tomllib before writing, and is a no-op when the
# config already says the right thing (it is byte-identical on our Linux box).
# ---------------------------------------------------------------------------
if [ ! -f "$GW_TOML" ]; then
  cat >&2 <<EOF
$GW_TOML does not exist. An OpenShell gateway config already includes TLS,
mTLS and JWT settings generated by openshell-gateway's first boot; creating a
fresh one here would silently drop them. Start the gateway once so it
generates its config, or copy the verified layout from
docs/OpenClaw-OpenShell.md ("Advanced" section), then rerun this script.
EOF
  exit 1
fi

if grep -q '^version = 1' "$GW_TOML"; then
  cat >&2 <<EOF
$GW_TOML is schema v1 (OpenShell 0.0.x). The upstream-proxy stanza needs
schema v2 (OpenShell >= 0.1.x): migrate per docs/OpenClaw-OpenShell.md
("Advanced" section) — version = 2, compute_driver, guest_tls_ca moved to
[openshell.gateway], drop sandbox_namespace/network_name/guest_tls_cert/
guest_tls_key — then rerun this script.
EOF
  exit 1
fi

mkdir -p "$OPENSSH_CONFIG_DIR"

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
patch_out=$(python3 "$DEMO_DIR/patch-driver-config.py" \
  "$GW_TOML" \
  "$PROXY_URL" \
  "$OPENSSH_CONFIG_DIR/upstream-proxy-auth" \
  docker)
printf '%s\n' "$patch_out"
# A patched config is inert until the gateway reads it; the 2026-10 Mac loop
# (patch, then keep using the old process) manifests as the exact same
# "podman API error" over and over. Restart the brew service right here on
# macOS — Linux/NemoClaw boxes are restarted per their own instructions.
config_changed=0
case "$patch_out" in *"already up to date"*) ;; *) config_changed=1 ;; esac
if [ "$config_changed" -eq 1 ] && [ "$(uname -s)" = Darwin ] \
   && command -v brew >/dev/null 2>&1 \
   && brew services list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qxF openshell; then
  info "Restarting the brew-managed gateway to activate the patched config"
  brew services restart nvidia/openshell/openshell 2>/dev/null || brew services restart openshell
  gw_up=0
  for _ in $(seq 1 30); do
    if curl -sk -m 2 -o /dev/null "$GATEWAY_URL" 2>/dev/null; then gw_up=1; break; fi
    sleep 1
  done
  if [ "$gw_up" -ne 1 ]; then
    echo "✗ gateway did not come back after the service restart" >&2
    tail -n 40 /opt/homebrew/var/log/openshell/openshell-gateway.err.log 2>/dev/null || true
    exit 1
  fi
  echo "✓ gateway back up"
fi

info "Gateway config updated — RESTART the OpenShell gateway to activate it"
cat <<EOF
  macOS gateway from NVIDIA's install.sh (brew tap nvidia/openshell):
                                 done automatically above when the config changed
  manually-run gateway:          stop the exact 'openshell-gateway' process and
                                 relaunch it with the same flags/env
  NemoClaw/system-managed box:   systemctl --user restart openshell-gateway
  (or simply: demo/start-openshell-gateway.sh handles both modes on the Mac)
EOF

# Register the local OpenShell gateway if needed. A stale registration under
# the same name (earlier setup run, or a different endpoint) is re-registered
# rather than hard-erroring: remove + add keeps the endpoint current. A
# different name can be chosen with --name on the add line.
if ! openshell gateway list 2>/dev/null | grep -q '^\*\s*openshell\s'; then
  if ! openshell gateway add --local "$GATEWAY_URL" --name openshell 2>&1; then
    info "gateway 'openshell' exists (or add failed) — replacing the registration"
    openshell gateway remove openshell 2>/dev/null || true
    openshell gateway add --local "$GATEWAY_URL" --name openshell
  fi
else
  echo "OpenShell gateway already registered as 'openshell'"
fi

# Acquire a valid OIDC user ID token automatically in the demo environment.
# This avoids a brittle interactive Dex browser flow for regular local setup.
if [ -z "${ID_TOKEN:-}" ]; then
  info "Minting a user identity token from Dex"
  ID_TOKEN=$(curl -fsS -X POST "${DEX_URL}/dex/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=password' \
    --data-urlencode "username=${DEX_USER}@example.com" \
    --data-urlencode "password=${DEX_PASSWORD}" \
    --data-urlencode 'scope=openid email profile' \
    --data-urlencode 'client_id=agent-gateway' \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('id_token',''))" 2>/dev/null || true)
fi

if [ -z "${ID_TOKEN:-}" ]; then
  echo "Unable to mint a Dex ID token automatically. Set ID_TOKEN explicitly or supply DEX_USER/DEX_PASSWORD and rerun." >&2
  exit 1
fi

# Create the delegation that allows usual provider traffic while gating risky
# actions. The resource patterns are exposed to the agent, while OpenShell's
# sandbox policy adds the default-deny egress boundary.
info "Creating the Agent Gateway delegation"
DELEGATION=$(curl -sS -X POST "$AUTHZ_URL/v1/delegations/" \
  -H 'Content-Type: application/json' \
  -d "{\"agent_id\":\"openshell-agent-1\",\"resources\":[\"api.openrouter.ai\",\"openrouter.ai\",\"*.openrouter.ai\",\"api.github.com\",\"catalog.openclaw.ai\",\"clawhub.ai\"],\"actions\":[\"read\",\"create\",\"connect\",\"delete\"],\"expires_in_seconds\":1800,\"ttl_seconds\":1800,\"id_token\":\"$ID_TOKEN\",\"approval_rules\":[{\"when\":{\"resource_pattern\":\"*\",\"action_pattern\":\"connect\"},\"require\":true,\"rationale\":\"dangerous outbound connects require human approval\"},{\"when\":{\"resource_pattern\":\"*\",\"action_pattern\":\"delete\"},\"require\":true,\"rationale\":\"destructive outbound deletes require human approval\"}]}" )

DELEGATION_ID=$(printf '%s' "$DELEGATION" | python3 -c "import sys,json; print(json.load(sys.stdin)['delegation']['id'])" 2>/dev/null || true)
AGENT_SECRET=$(printf '%s' "$DELEGATION" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agent_secret',''))" 2>/dev/null || true)

if [ -z "$DELEGATION_ID" ] || [ -z "$AGENT_SECRET" ]; then
  echo "Delegation creation failed: $DELEGATION" >&2
  exit 1
fi

AGENT_TOKEN=$(curl -sS -X POST "$TOKENSVC_URL" \
  -H 'Content-Type: application/json' \
  -d "{\"delegation_id\":\"$DELEGATION_ID\",\"ttl_seconds\":600,\"agent_secret\":\"$AGENT_SECRET\"}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token') or d.get('token',''))" 2>/dev/null || true)

if [ -z "$AGENT_TOKEN" ]; then
  echo "Failed to mint the short-lived agent token." >&2
  exit 1
fi

if [ "$CHECK_ONLY" -eq 0 ]; then
  printf '%s:x\n' "$AGENT_TOKEN" > "$OPENSSH_CONFIG_DIR/upstream-proxy-auth"
  chmod 600 "$OPENSSH_CONFIG_DIR/upstream-proxy-auth"
fi

# The live OpenShell sandbox must be allowed to reach the outbound destinations
# it is expected to use. Keep this minimal: only the OpenRouter, OpenClaw catalog,
# and GitHub release-check endpoints that OpenClaw probes during normal startup.
# The gateway continues to decide on approval/high-risk actions.
if ! openshell sandbox list 2>/dev/null | awk '{print $1}' | grep -qx "$SANDBOX_NAME"; then
  # Provision via demo/openclaw-sandbox.sh, not a bare `openshell sandbox
  # create`: this script has no image name of its own and the sandbox needs
  # what openclaw-sandbox.sh provides — the agent-gateway-demo/openclaw image,
  # the `openclaw gateway run` command, SQLITE_TMPDIR, and the env SecretRef.
  # (A bare create with a made-up image ref 404s on docker.io and would boot
  # nothing; this fallback line only ever runs when the sandbox is missing.)
  info "No sandbox '$SANDBOX_NAME' — creating it via demo/openclaw-sandbox.sh"
  SANDBOX_NAME="$SANDBOX_NAME" bash "$DEMO_DIR/openclaw-sandbox.sh" up
fi

apply_openrouter_policy "$SANDBOX_NAME"

info "OpenShell gateway setup complete"
cat <<EOF

Set the environment for manual testing:
  export PROXY_URL=http://127.0.0.1:8088
  export AUTHZ_URL=http://127.0.0.1:8081
  export TOKENSVC_URL=http://127.0.0.1:8082/token

Verified wiring:
  - ${OPENSSH_CONFIG_DIR}/gateway.toml points at ${PROXY_URL}
  - ${OPENSSH_CONFIG_DIR}/upstream-proxy-auth contains the delegation token
  - upstream gateway: ${GATEWAY_URL}
  - sandbox: ${SANDBOX_NAME}
  - delegation: ${DELEGATION_ID}

Important:
  - the sandbox remains default-deny
  - the intended outbound allowlist is: OpenRouter, OpenClaw catalog, GitHub release checks
  - risky actions like CONNECT / DELETE are still handled by the gateway
  - generic internet access remains blocked

Next: run ./demo/openshell.sh to exercise the allowed-path and approval-gated-path checks.
EOF

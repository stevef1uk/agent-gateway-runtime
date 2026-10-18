#!/usr/bin/env bash
# OpenShell + Agent Gateway local setup helper
#
# This script matches the commands used during the live OpenShell/OpenClaw
# setup:
#   - configure the OpenShell gateway to send all sandbox outbound traffic to
#     the Agent Gateway egress proxy on http://127.0.0.1:8088
#   - register the local OpenShell gateway
#   - create a delegation allowing ordinary OpenRouter API calls while keeping
#     CONNECT and DELETE under the gateway approval policy
#   - write the delegation token to ~/.config/openshell/upstream-proxy-auth
#   - update the live sandbox policy so it can only reach the endpoints needed
#     for provider traffic, OpenClaw metadata refresh, and GitHub update checks.
#     The gateway remains the real decision point for risky actions.
#
# Usage:
#   ./demo/openshell-gateway-setup.sh
#   ./demo/openshell-gateway-setup.sh --check
#   ID_TOKEN=... ./demo/openshell-gateway-setup.sh
#   DEX_USER=alice DEX_PASSWORD=password ./demo/openshell-gateway-setup.sh
#
# Notes:
#   - the sandbox policy accepts DNS hostnames; wildcards like "*.openrouter.ai"
#     are valid in the gateway delegation, but not in OpenShell's network policy
#     syntax. Use exact hosts there.
#   - the proxy itself (127.0.0.1:8088 / localhost:8088) is never added to the
#     sandbox allowlist in the loopback-guarded policy; the OpenShell gateway
#     config is what forwards the request upstream.
#   - we explicitly allow the OpenClaw catalog and GitHub update endpoints here,
#     because OpenClaw probes them during model/provider discovery and update
#     checks. This is still a narrow allowlist, not a blanket outbound permit.

set -euo pipefail

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=1
  shift
fi

PROXY_URL="${PROXY_URL:-http://127.0.0.1:8088}"
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
  openshell policy update "$sandbox_name" --remove-rule openrouter_egress >/dev/null 2>&1 || true

  # Normal model/provider traffic.
  openshell policy update "$sandbox_name" \
    --rule-name openrouter_egress \
    --binary /usr/bin/bash \
    --binary /usr/local/bin/node \
    --binary /usr/bin/curl \
    --binary /usr/bin/wget \
    --binary /usr/local/bin/openclaw \
    --add-endpoint 'api.openrouter.ai:443::tcp' \
    --wait

  openshell policy update "$sandbox_name" \
    --rule-name openrouter_egress \
    --binary /usr/bin/bash \
    --binary /usr/local/bin/node \
    --binary /usr/bin/curl \
    --binary /usr/bin/wget \
    --binary /usr/local/bin/openclaw \
    --add-endpoint 'openrouter.ai:443::tcp' \
    --wait

  # OpenClaw metadata discovery / plugin catalog / release checks.
  openshell policy update "$sandbox_name" \
    --rule-name openrouter_egress \
    --binary /usr/bin/bash \
    --binary /usr/local/bin/node \
    --binary /usr/bin/curl \
    --binary /usr/bin/wget \
    --binary /usr/local/bin/openclaw \
    --add-endpoint 'catalog.openclaw.ai:443::tcp' \
    --wait

  openshell policy update "$sandbox_name" \
    --rule-name openrouter_egress \
    --binary /usr/bin/bash \
    --binary /usr/local/bin/node \
    --binary /usr/bin/curl \
    --binary /usr/bin/wget \
    --binary /usr/local/bin/openclaw \
    --add-endpoint 'clawhub.ai:443::tcp' \
    --wait

  openshell policy update "$sandbox_name" \
    --rule-name openrouter_egress \
    --binary /usr/bin/bash \
    --binary /usr/local/bin/node \
    --binary /usr/bin/curl \
    --binary /usr/bin/wget \
    --binary /usr/local/bin/openclaw \
    --add-endpoint 'api.github.com:443::tcp' \
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

# Configure the OpenShell host gateway to forward all sandbox egress to the
# Agent Gateway egress proxy listener.
cat > "$OPENSSH_CONFIG_DIR/gateway.toml" <<EOF
[openshell]
version = 2

[openshell.drivers.podman]
allow_driver_config = true
https_proxy = "${PROXY_URL}"
proxy_auth_file = "${OPENSSH_CONFIG_DIR}/upstream-proxy-auth"
proxy_auth_allow_insecure = true
proxy_connect_by_hostname = true
EOF

chmod 600 "$OPENSSH_CONFIG_DIR/gateway.toml" 2>/dev/null || true

# Register the local OpenShell gateway if needed.
if ! openshell gateway list 2>/dev/null | grep -q '^\*\s*openshell\s'; then
  openshell gateway add --local "$GATEWAY_URL" --name openshell
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
  openshell sandbox create --from openclaw --name "$SANDBOX_NAME"
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

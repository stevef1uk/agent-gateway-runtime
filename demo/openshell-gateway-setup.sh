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

if [ "$CHECK_ONLY" -eq 1 ]; then
  info "--check: reporting current state only (no writes)"
  if [ -f "$OPENSSH_CONFIG_DIR/gateway.toml" ]; then
    grep -E "^(version|https_proxy|proxy_auth_file|proxy_connect_by_hostname|proxy_auth_allow_insecure) ?=" "$OPENSSH_CONFIG_DIR/gateway.toml" || true
    grep -q '^https_proxy.*=.*8088' "$OPENSSH_CONFIG_DIR/gateway.toml" \
      && echo "  ✓ upstream proxy stanza present" \
      || echo "  ✗ upstream proxy stanza missing"
  else
    echo "  ✗ $OPENSSH_CONFIG_DIR/gateway.toml missing"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Patch the OpenShell gateway config with the upstream-proxy stanza WITHOUT
# clobbering the rest (TLS, mTLS, JWT, credential config stay as they are).
# ---------------------------------------------------------------------------
GW_TOML="$OPENSSH_CONFIG_DIR/gateway.toml"
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
UPSTREAM_BLOCK='[openshell.drivers.docker]'

# Upsert the upstream-proxy keys into the ACTIVE driver section of the
# schema-v2 gateway config (or append the docker driver section when absent).
python3 - "$GW_TOML" "$PROXY_URL" "$OPENSSH_CONFIG_DIR/upstream-proxy-auth" <<'PYEOF'
import re, sys

path, proxy, authfile = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path).read()
keys = {
    'https_proxy':                proxy,
    'proxy_auth_file':            authfile,
    'proxy_auth_allow_insecure':  'true',
    'proxy_connect_by_hostname':  'true',
}
for name, tbl in (('docker', '[openshell.drivers.docker]'), ('podman', '[openshell.drivers.podman]')):
    mt = re.search(rf'^\[{re.escape(tbl)}\]\s*$', src, re.M)
    if mt:
        break
else:
    name, tbl, mt = 'docker', '[openshell.drivers.docker]', None

if mt is None:
    src = src.rstrip('\n') + f'\n\n{tbl}\n' + '\n'.join(f'{k} = "{v if name == "https_proxy" or k != "proxy_auth_allow_insecure" else v}"' if k != 'proxy_auth_allow_insecure' else f'{k} = true' for k, v in keys.items()) + '\n'
else:
    section = re.compile(rf'(?ms)^\[{re.escape(tbl)}\]\s*$.*?(?=^\[|\Z)')
    def section_body(c):
        body = c.group(0)
        for k, v in keys.items():
            lit = f'{k} = true' if v in ('true', 'false') else f'{k} = "{v}"'
            pat = rf'^{k} ?=.*$'
            if re.search(pat, body, re.M):
                body = re.sub(pat, lit, body, flags=re.M)
            else:
                body = body.rstrip('\n') + '\n' + lit + '\n'
        return body
    src = section.sub(section_body, src, count=1)

open(path, 'w').write(src)
print(f'patched [{tbl}] in {path}')
PYEOF

# Preserve restrictive perms on the TOML (it names the credential file).
chmod 600 "$GW_TOML" 2>/dev/null || true

info "Gateway config patched — RESTART the OpenShell gateway to activate it"
cat <<EOF
  NemoClaw/system-managed box:  systemctl --user restart openshell-gateway
  manually-run gateway:         stop the exact 'openshell-gateway' process and
                                relaunch it with the same flags/env
  macOS:                        brew services restart openshell-gateway
EOF

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

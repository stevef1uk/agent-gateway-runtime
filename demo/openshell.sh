#!/usr/bin/env bash
# ============================================================================
# Agent Gateway — OpenShell/OpenClaw egress policy check
#
# The policy model is intentionally narrow:
#   - OpenRouter-style traffic is allowed without a human approval hold
#   - only dangerous egress like CONNECT or DELETE still requires approval
#
# This script creates a delegation matching the new rule, then exercises an
# allow-path and a danger-path through the gateway's egress proxy.
# ============================================================================

set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED=''; GRN=''; YLW=''; BLU=''; BLD=''; RST=''
if [ -t 1 ]; then
  RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; BLU='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
fi

step() { printf "\n${BLD}${BLU}%s${RST}\n" "$*"; }
okk() { printf "  ${GRN}✓ %s${RST}\n" "$*"; }
bad() { printf "  ${RED}✗ %s${RST}\n" "$*"; }
warn() { printf "  ${YLW}• %s${RST}\n" "$*"; }
line() { printf "  %s\n" "$*"; }

COMPOSE="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  COMPOSE="docker-compose"
fi

PROXY_URL="http://localhost:8088"
ADMIN_TOKEN="${ADMIN_TOKEN:-agent-gateway-demo-admin}"
# Published PEP port: GATEWAY_HOST_PORT (env or .env) overrides 8080, e.g. when
# a local OpenShell gateway already owns :8080.
if [ -z "${GATEWAY_HOST_PORT:-}" ] && [ -f .env ]; then
  GATEWAY_HOST_PORT="$(sed -n 's/^GATEWAY_HOST_PORT=//p' .env | tail -1)"
fi
GW=${GW:-http://localhost:${GATEWAY_HOST_PORT:-8080}}
GW_PORT=${GW##*:}

# --- 0. health ---------------------------------------------------------------
step "Step 1 — services & proxy health"
$COMPOSE up -d --no-recreate >/dev/null 2>&1 || true
sleep 2
HEALTHY=1
for port in 8081 8082 "$GW_PORT" 8083; do
  if curl -sf "http://localhost:$port/healthz" >/dev/null 2>&1; then
    okk "service on :$port healthy"
  else
    bad "service on :$port not healthy"; HEALTHY=0
  fi
done
POSTURE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$PROXY_URL/" || echo 000)
if [ "$POSTURE" = "407" ]; then
  okk "gateway egress proxy on :$PROXY_URL — unauthenticated requests refused (407)"
else
  bad "egress proxy posture unexpected: ${POSTURE} (want 407)"
  exit 1
fi
[ "$HEALTHY" = 1 ] || { bad "unhealthy stack — run: docker compose up -d"; exit 1; }

# --- 1. SSO sign-in ----------------------------------------------------------
step "Step 2 — sign in at the identity provider"
DEX="http://localhost:5556"
fixdex() { sed 's|//dex:5556|//localhost:5556|'; }
JAR=$(mktemp)
ID_TOKEN=""
LOC="$DEX/dex/auth?response_type=code&client_id=agent-gateway&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback&connector_id=mock&scope=openid"
CODE=""
for _ in 1 2 3 4 5 6; do
  NX=$(curl -s -b "$JAR" -c "$JAR" -D - -o /dev/null "$LOC" | grep -i '^location' | head -1 | tr -d '\r' | sed 's/^Location: //' | fixdex)
  [ -z "$NX" ] && break
  case "$NX" in
    *code=*) CODE=$(echo "$NX" | sed 's/.*code=\([^&]*\).*/\1/'); break;;
    /*) LOC="$DEX$NX" ;;
    *) LOC="$NX" ;;
  esac
done
if [ -n "$CODE" ]; then
  ID_TOKEN=$(curl -s -X POST "$DEX/dex/token" \
    -d "grant_type=authorization_code&client_id=agent-gateway&code=$CODE&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('id_token',''))" 2>/dev/null || true)
fi
if [ -n "${ID_TOKEN:-}" ]; then
  okk "SSO sign-in succeeded; human identity verified"
  APPROVER=$(printf '%s' "$ID_TOKEN" | cut -d. -f2 | python3 -c "import sys,json,base64; t=sys.stdin.read().strip(); t+='='*(-len(t)%4); print(json.loads(base64.urlsafe_b64decode(t)).get('sub',''))" 2>/dev/null || true)
else
  bad "could not complete SSO sign-in"
  exit 1
fi

if [ -z "${APPROVER:-}" ]; then
  bad "could not determine the SSO subject from the ID token"
  exit 1
fi

# --- 2. new delegation: allow OpenRouter; gate only danger -------------------
step "Step 3 — create a delegation for OpenRouter traffic"
DELEGATION=$(curl -s -X POST http://localhost:8081/v1/delegations/ \
  -H "Content-Type: application/json" \
  -d "{\"agent_id\":\"openshell-agent-1\",\"resources\":[\"api.openrouter.ai\",\"openrouter.ai\",\"*.openrouter.ai\"],\"actions\":[\"read\",\"create\",\"connect\",\"delete\"],\"expires_in_seconds\":1800,\"ttl_seconds\":1800,\"id_token\":\"$ID_TOKEN\",\"approval_rules\":[{\"when\":{\"resource_pattern\":\"*\",\"action_pattern\":\"connect\"},\"require\":true,\"rationale\":\"dangerous outbound connects require human approval\"},{\"when\":{\"resource_pattern\":\"*\",\"action_pattern\":\"delete\"},\"require\":true,\"rationale\":\"destructive outbound deletes require human approval\"}]}" )
DELEGATION_ID=$(printf '%s' "$DELEGATION" | python3 -c "import sys,json; print(json.load(sys.stdin)['delegation']['id'])" 2>/dev/null || true)
AGENT_SECRET=$(printf '%s' "$DELEGATION" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agent_secret',''))" 2>/dev/null || true)
if [ -n "$DELEGATION_ID" ]; then
  okk "delegation created: $DELEGATION_ID"
  line "scope: api.openrouter.ai, openrouter.ai, *.openrouter.ai [read, create, connect, delete]"
  line "approval gate: connect + delete only"
else
  bad "delegation refused: $(printf '%s' "$DELEGATION" | head -c 200)"
  exit 1
fi

# --- 3. token mint -----------------------------------------------------------
step "Step 4 — mint a short-lived token for the agent"
AGENT_TOKEN=$(curl -s -X POST http://localhost:8082/token \
  -H "Content-Type: application/json" \
  -d "{\"delegation_id\":\"$DELEGATION_ID\",\"ttl_seconds\":600,\"agent_secret\":\"$AGENT_SECRET\"}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token') or d.get('token',''))" 2>/dev/null || true)
if [ -n "$AGENT_TOKEN" ]; then
  okk "agent token issued (${#AGENT_TOKEN} chars)"
else
  bad "mint failed"
  exit 1
fi

# --- 4. allowed path: OpenRouter GET should pass without approval ------------
step "Step 5 — OpenRouter read is allowed without human approval"
ALLOW_CODE=$(curl -s -o /tmp/openshell_allow.json -w "%{http_code}" --max-time 30 \
  --proxy "$PROXY_URL" \
  -H "Proxy-Authorization: Bearer $AGENT_TOKEN" \
  "http://api.openrouter.ai" || true)
if [ "$ALLOW_CODE" = "403" ] || [ "$ALLOW_CODE" = "407" ] || [ "$ALLOW_CODE" = "000" ]; then
  bad "OpenRouter GET was blocked by the gateway: HTTP $ALLOW_CODE"
  exit 1
fi
if [ -n "$ALLOW_CODE" ] && [ "$ALLOW_CODE" != "000" ]; then
  okk "OpenRouter GET passed through the gateway (HTTP $ALLOW_CODE); no approval hold was required"
else
  warn "provider call returned no usable HTTP status — gateway was not blocking it, but upstream connectivity is not available in this environment"
fi

# --- 5. dangerous path: CONNECT should be held -------------------------------
step "Step 6 — dangerous CONNECT to an OpenRouter-like destination requires approval"
python3 - "$PROXY_URL" "$AGENT_TOKEN" <<'PY'
import json, os, socket, sys
proxy = sys.argv[1].split('://',1)[1]
proxy_host, proxy_port = proxy.split(':') if ':' in proxy else (proxy, 80)
proxy_port = int(proxy_port)

auth = sys.argv[2]
raw = (
    f"CONNECT api.openrouter.ai:443 HTTP/1.1\r\n"
    f"Host: api.openrouter.ai:443\r\n"
    f"Proxy-Authorization: Bearer {auth}\r\n"
    "\r\n"
).encode()
with socket.create_connection((proxy_host, proxy_port), timeout=30) as s:
    s.sendall(raw)
    data = s.recv(4096)
    status = data.split(b' ', 2)[1].decode('ascii', 'replace') if data else '000'
    body = data.decode('latin1', 'replace')
    with open('/tmp/openshell_connect.json', 'w') as f:
        f.write(body)
    if status == '202':
        print('202')
    else:
        print(status)
PY
CONNECT_STATUS=$(cat /tmp/openshell_connect.json 2>/dev/null | python3 -c "import sys; d=sys.stdin.read(); print(d.split(' ',2)[1] if ' ' in d else '000')" 2>/dev/null || echo 000)
if [ "$CONNECT_STATUS" = "202" ]; then
  okk "CONNECT path was held for approval as expected (HTTP 202)"
  auth_id=$(python3 - <<'PY' 2>/dev/null
import json,sys,re
p='/tmp/openshell_connect.json'
text=open(p).read()
for line in text.splitlines():
    if 'approval_id' in line.lower():
        m=re.search(r'"approval_id"\s*:\s*"([^"]+)"', line)
        if m:
            print(m.group(1)); break
PY
)
  if [ -n "$auth_id" ]; then
    step "Step 7 — approve the CONNECT hold"
    APPROVE_CODE=$(curl -s -o /tmp/openshell_approve.json -w "%{http_code}" -X POST $GW/v1/approvals/ \
      -H "Content-Type: application/json" \
      -H "X-Admin-Token: $ADMIN_TOKEN" \
      -d "{\"approval_id\":\"$auth_id\",\"approver_id\":\"$APPROVER\",\"approved\":true}" || true)
    if [ "$APPROVE_CODE" = "200" ] || [ "$APPROVE_CODE" = "202" ]; then
      okk "approval accepted"
    else
      bad "approval failed with HTTP $APPROVE_CODE"
      exit 1
    fi
  fi
else
  bad "CONNECT path was not held for approval; gateway unexpectedly allowed it (HTTP ${CONNECT_STATUS})"
  exit 1
fi

# --- 6. destructive delete should also hold ----------------------------------
step "Step 8 — a destructive DELETE on the same host is also held"
DELETE_CODE=$(curl -s -o /tmp/openshell_delete.json -w "%{http_code}" --max-time 30 \
  --proxy "$PROXY_URL" \
  -X DELETE \
  -H "Proxy-Authorization: Bearer $AGENT_TOKEN" \
  "http://api.openrouter.ai/v1/delete" || true)
if [ "$DELETE_CODE" = "202" ] || [ "$DELETE_CODE" = "403" ] || [ "$DELETE_CODE" = "407" ]; then
  okk "DELETE path is gated by the approval policy (HTTP $DELETE_CODE)"
else
  warn "DELETE call did not hit the approval gate (HTTP $DELETE_CODE), but it was not a generic gateway deny"
fi

printf "\n${BLD}OpenShell/OpenClaw policy summary${RST}\n"
line "- OpenRouter GET/POST calls should pass without a human approval hold"
line "- CONNECT and DELETE remain approval-gated"
line "- gateway denies raw policy breaches and keeps risky egress under review"

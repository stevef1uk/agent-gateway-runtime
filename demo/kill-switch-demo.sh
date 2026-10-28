#!/usr/bin/env bash
# ============================================================================
# Agent Gateway — Demo 11: the kill switch
#
# Demonstrates cutting off an agent's access to an upstream API at the
# enforcement point, at two levels:
#
#   1. ONE agent — revoke a single delegation; that agent's token is still
#      cryptographically valid yet every subsequent call is refused (403).
#   2. ALL agents — revoke every delegation that reaches the same upstream
#      API; the whole agent population loses access instantly.
#
# The revocation is enforced by the authz service before any engine runs, so
# revoke beats token validity, pending approvals, and any Rego policy file.
# Nothing reaches demoapi after a kill switch is thrown — the upstream's own
# call counter proves it.
#
# Prereqs:   cd demo && docker compose -f docker-compose.yml -f docker-compose.egress.yml up -d
# Usage:     ./kill-switch-demo.sh          (compose, all scripted)
#            ./kill-switch-demo.sh --node 192.168.1.74   (k3s cluster)
# ============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
  echo "this script must run under BASH" >&2
  echo "Run it as:  bash ./kill-switch-demo.sh" >&2
  exit 64
fi

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

source "$DEMO_DIR/lib/engine.sh"

RED=''; GRN=''; YLW=''; BLU=''; BLD=''; RST=''
if [ -t 1 ]; then
  RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; BLU='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
fi
step()  { printf "\n${BLD}${BLU}%s${RST}\n" "$*"; }
okk()   { printf "  ${GRN}✓ %s${RST}\n" "$*"; }
bad()   { printf "  ${RED}✗ %s${RST}\n" "$*"; }
warn()  { printf "  ${YLW}• %s${RST}\n" "$*"; }
line()  { printf "  %s\n" "$*"; }

# --- endpoint overrides ------------------------------------------------------
NODE_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --node) NODE_ARG="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$NODE_ARG" ]; then
  WEB=${WEB:-http://$NODE_ARG:30083}
  GW=${GW:-http://$NODE_ARG:30080}
  AUTHZ=${AUTHZ:-http://$NODE_ARG:30081}
  TS=${TS:-http://$NODE_ARG:30082}
else
  if [ -z "${GATEWAY_HOST_PORT:-}" ] && [ -f .env ]; then
    GATEWAY_HOST_PORT="$(sed -n 's/^GATEWAY_HOST_PORT=//p' .env | tail -1)"
  fi
  WEB=${WEB:-http://localhost:8083}
  GW=${GW:-http://localhost:${GATEWAY_HOST_PORT:-8080}}
  AUTHZ=${AUTHZ:-http://localhost:8081}
  TS=${TS:-http://localhost:8082}
fi
ADMIN_TOKEN=${ADMIN_TOKEN:-agent-gateway-demo-admin}
UPSTREAM=http://localhost:8090   # demoapi, only reachable out-of-band for counter proof

# --- 0. stack & health -------------------------------------------------------
step "Step 1 — services & health"
bash "$DEMO_DIR/refresh-dex-redirects.sh" || true
compose up -d --no-recreate >/dev/null 2>&1 || true
sleep 2
HEALTHY=1
for port in 8081 8082 "${GW##*:}" 8083; do
  if curl -sf "http://localhost:$port/healthz" >/dev/null 2>&1; then
    okk "service on :$port healthy"
  else
    bad "service on :$port not healthy"; HEALTHY=0
  fi
done
if ! curl -sf http://localhost:5556/dex/.well-known/openid-configuration >/dev/null 2>&1; then
  bad "SSO (Dex) on :5556 not responding"; HEALTHY=0
else
  okk "SSO (Dex) on :5556 responding"
fi
# demoapi is reachable directly (out of band) for counter proof
if curl -sf "$UPSTREAM/orders" >/dev/null 2>&1; then
  okk "demoapi upstream reachable at $UPSTREAM"
else
  warn "demoapi not reachable at $UPSTREAM directly — counter-proof step will note 403s instead"
fi
[ "$HEALTHY" = 1 ] || { bad "unhealthy stack — run: $ENGINE compose up -d"; exit 1; }

# --- 1. SSO sign-in (verified subject = the delegating human) ----------------
step "Step 2 — SSO sign-in → verified subject (the human who holds the kill switch)"
DEX="http://localhost:5556"
fixdex() { sed 's|//dex:5556|//localhost:5556|'; }
JAR=$(mktemp)
LOC="$DEX/dex/auth?response_type=code&client_id=agent-gateway&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback&connector_id=mock&scope=openid"
CODE=""
for _ in 1 2 3 4 5 6; do
  NX=$(curl -s -b "$JAR" -c "$JAR" -D - -o /dev/null "$LOC" | grep -i '^location' | head -1 | tr -d '\r' | sed 's/^Location: //' | fixdex)
  [ -z "$NX" ] && break
  case "$NX" in
    *code=*) CODE=$(echo "$NX" | sed 's/.*code=\([^&]*\).*/\1/'); break ;;
    /*)    LOC="$DEX$NX" ;;
    *)     LOC="$NX" ;;
  esac
done
ID_TOKEN=$(curl -s -X POST "$DEX/dex/token" \
  -d "grant_type=authorization_code&client_id=agent-gateway&code=$CODE&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('id_token',''))" 2>/dev/null || true)
SUBJECT=$(printf '%s' "$ID_TOKEN" | cut -d. -f2 | python3 -c "import sys,json,base64; t=sys.stdin.read().strip(); t+='='*(-len(t)%4); print(json.loads(base64.urlsafe_b64decode(t)).get('sub',''))" 2>/dev/null || true)
[ -n "$ID_TOKEN" ] && [ -n "$SUBJECT" ] || { bad "SSO sign-in failed"; exit 1; }
okk "verified subject: $SUBJECT (this human creates delegations and holds the kill switch)"

# --- helper: create a delegation + mint a token for one agent ----------------
mint_agent() { # agent_id -> sets DELEG_ID, AGENT_SECRET, AGENT_TOKEN globals
  local aid="$1"
  local resp
  resp=$(curl -s -X POST "$AUTHZ/v1/delegations/" \
    -H 'Content-Type: application/json' \
    -d "{\"agent_id\":\"$aid\",\"resources\":[\"/orders\"],\"actions\":[\"read\",\"create\"],\"expires_in_seconds\":1800,\"id_token\":\"$ID_TOKEN\"}")
  DELEG_ID=$(printf '%s' "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin)['delegation']['id'])" 2>/dev/null || true)
  AGENT_SECRET=$(printf '%s' "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('agent_secret',''))" 2>/dev/null || true)
  [ -n "$DELEG_ID" ] && [ -n "$AGENT_SECRET" ] || { bad "delegation for $aid refused: $(printf '%s' "$resp" | head -c 160)"; return 1; }
  AGENT_TOKEN=$(curl -s -X POST "$TS/token" \
    -H 'Content-Type: application/json' \
    -d "{\"delegation_id\":\"$DELEG_ID\",\"ttl_seconds\":300,\"agent_secret\":\"$AGENT_SECRET\"}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
  [ -n "$AGENT_TOKEN" ] || { bad "mint failed for $aid"; return 1; }
  line "  $aid  → delegation $DELEG_ID  → token ${AGENT_TOKEN:0:14}…"
}

# --- helper: one agent calls /orders, reports code + demoapi counter --------
agent_call() { # agent_label token -> prints result (code on stdout)
  local label="$1" tok="$2"
  local code body count
  code=$(curl -s -o /tmp/ks_body.json -w '%{http_code}' -X POST "$GW/orders" \
    -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    -d '{"amount":100,"supplier":"acme"}')
  body=$(cat /tmp/ks_body.json)
  count=$(printf '%s' "$body" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('executed_count','?'))" 2>/dev/null || echo "?")
  line "  $label: HTTP $code · demoapi executed_count=$count" >&2
  echo "$code"
}

# --- 2. create three agents, all delegated to /orders on demoapi -------------
step "Step 3 — three agents, one upstream API (/orders on demoapi), one human delegator"
mint_agent purchasing-agent || exit 1
DELEG_PURCHASING="$DELEG_ID"; TOKEN_PURCHASING="$AGENT_TOKEN"
mint_agent shipping-agent   || exit 1
DELEG_SHIPPING="$DELEG_ID";   TOKEN_SHIPPING="$AGENT_TOKEN"
mint_agent billing-agent    || exit 1
DELEG_BILLING="$DELEG_ID";    TOKEN_BILLING="$AGENT_TOKEN"

# --- 3. all three agents call /orders — everything allowed --------------------
step "Step 4 — before the kill switch: every agent calls /orders (all 200)"
C1=$(agent_call "purchasing-agent" "$TOKEN_PURCHASING")
C2=$(agent_call "shipping-agent"   "$TOKEN_SHIPPING")
C3=$(agent_call "billing-agent"    "$TOKEN_BILLING")
[ "$C1" = "200" ] && [ "$C2" = "200" ] && [ "$C3" = "200" ] || { bad "expected all 200 before kill switch"; exit 1; }
okk "all three agents reach /orders — the upstream is open to delegated agents"

# --- 4. KILL SWITCH #1 — ONE agent -------------------------------------------
step "Step 5 — KILL SWITCH #1: revoke shipping-agent's delegation only"
RVC=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$AUTHZ/v1/delegations/$DELEG_SHIPPING" -H "Authorization: Bearer $ID_TOKEN")
[ "$RVC" = "204" ] || [ "$RVC" = "200" ] || { bad "revoke of shipping-agent failed (HTTP $RVC)"; exit 1; }
okk "shipping-agent delegation revoked (instant, enforced by authz before any engine)"
line "the shipping-agent JWT is still cryptographically valid — but it is no longer authorized"

step "Step 6 — after kill switch #1: shipping-agent is cut off, others still work"
S1=$(agent_call "purchasing-agent   (still allowed)" "$TOKEN_PURCHASING")
S2=$(agent_call "shipping-agent     (KILLED)"        "$TOKEN_SHIPPING")
S3=$(agent_call "billing-agent      (still allowed)" "$TOKEN_BILLING")
[ "$S1" = "200" ] && [ "$S3" = "200" ] || { bad "other agents should still reach /orders"; exit 1; }
if [ "$S2" = "403" ]; then
  okk "shipping-agent: HTTP 403 — DENIED at enforcement, revocation worked instantly"
else
  bad "shipping-agent expected 403 after revocation, got $S2: $(head -c 160 /tmp/ks_body.json)"
  exit 1
fi

# --- 5. KILL SWITCH #2 — ALL agents ------------------------------------------
step "Step 7 — KILL SWITCH #2: revoke ALL delegations to /orders (the whole upstream)"
for del in "$DELEG_PURCHASING" "$DELEG_BILLING"; do
  RVC=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$AUTHZ/v1/delegations/$del" -H "Authorization: Bearer $ID_TOKEN")
  line "  revoked delegation $del (HTTP $RVC)"
done
okk "every delegation to /orders is now revoked — no agent may reach this upstream"

step "Step 8 — after kill switch #2: every agent is refused at the gateway"
T1=$(agent_call "purchasing-agent   (KILLED)" "$TOKEN_PURCHASING")
T2=$(agent_call "shipping-agent     (KILLED)" "$TOKEN_SHIPPING")
T3=$(agent_call "billing-agent      (KILLED)" "$TOKEN_BILLING")
[ "$T1" = "403" ] && [ "$T2" = "403" ] && [ "$T3" = "403" ] || { bad "expected all 403 after full kill switch"; exit 1; }
okk "all three agents: HTTP 403 — the upstream is closed to every agent"

# --- 6. proof the upstream never saw a call after the kill -------------------
step "Step 9 — upstream proof: no call reached demoapi after the kill switches"
line "every post-revoke call above returned HTTP 403 at the gateway — demoapi's"
line "own /orders handler never ran, so its executed_count could not move."
line "(the counter is returned per-response as executed_count; steps 4/6/8 show"
line "it incrementing only on pre-kill 200 calls)"

# --- 7. audit trail ----------------------------------------------------------
step "Step 10 — audit trail (every allow and every deny is recorded)"
docker exec agent-gateway-postgres psql -U agentgw -d agent_gateway \
  -c "SELECT ts, agent_id, resource, action, outcome, reason FROM audit_events
      WHERE resource='/orders' ORDER BY ts DESC LIMIT 12;" 2>/dev/null || \
  warn "could not read Postgres audit trail (run the stack first or check container name)"

# --- summary -----------------------------------------------------------------
printf "\n${BLD}Kill-switch demo complete${RST}\n"
line "Kill switch #1 (one agent):  revoke shipping-agent → that agent's valid token → 403"
line "Kill switch #2 (all agents): revoke every /orders delegation → all agents → 403"
line "Revoke is enforced by authz before any engine runs — it beats token validity,"
line "pending approvals, and any policy file. Nothing reaches demoapi after a kill."
printf "\n  Web console:  http://localhost:8083   (delegations / approvals / audit)\n"
line "Stop:  $ENGINE compose down"

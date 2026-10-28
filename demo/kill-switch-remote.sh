#!/usr/bin/env bash
# ============================================================================
# Agent Gateway — kill switch against a remote tenant (preprod / k3s / cloud)
#
# Demonstrates cutting off an agent's access to an upstream API at the
# enforcement point, at two levels:
#
#   1. ONE agent — revoke a single delegation; that agent's token is still
#      cryptographically valid yet every subsequent call is refused (403).
#   2. ALL agents — revoke every delegation that reaches the same upstream
#      API; the whole agent population loses access instantly.
#
# Unlike demo/kill-switch-demo.sh this variant does NOT run the local Dex
# SSO flow or touch localhost:8090. It expects you to supply:
#
#   - the gateway / authz / tokensvc base URLs (env or flags)
#   - a verified OIDC id_token (to create delegations bound to you)
#   - an operator/admin token (for the revocation calls)
#
# Revocation is enforced by authz before any engine runs, so it beats token
# validity, pending approvals, and any policy file — on any tenant.
#
# Usage (env):
#   GW=https://gw.preprod.agw.sjfisher.com \
#   AUTHZ=https://authz.preprod.agw.sjfisher.com \
#   TS=https://tokensvc.preprod.agw.sjfisher.com \
#   ID_TOKEN=<your OIDC id token> \
#   ADMIN_TOKEN=<operator token> \
#   ./kill-switch-remote.sh
#
# Usage (flags):
#   ./kill-switch-remote.sh \
#     --gateway https://gw.preprod.agw.sjfisher.com \
#     --authz   https://authz.preprod.agw.sjfisher.com \
#     --tokensvc https://tokensvc.preprod.agw.sjfisher.com \
#     --id-token  <id_token> \
#     --admin-token <admin_token> \
#     [--resource /orders] [--path /orders] [--amount 100]
# ============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
  echo "this script must run under BASH" >&2
  echo "Run it as:  bash ./kill-switch-remote.sh" >&2
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

# --- flags / env -------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --gateway)   GW="$2"; shift 2 ;;
    --authz)     AUTHZ="$2"; shift 2 ;;
    --tokensvc)  TS="$2"; shift 2 ;;
    --id-token)  ID_TOKEN="$2"; shift 2 ;;
    --admin-token) ADMIN_TOKEN="$2"; shift 2 ;;
    --resource)  RESOURCE="$2"; shift 2 ;;
    --path)      REQ_PATH="$2"; shift 2 ;;
    --amount)    AMOUNT="$2"; shift 2 ;;
    --help|-h)
      echo "usage: $0 [--gateway URL] [--authz URL] [--tokensvc URL] [--id-token JWT] [--admin-token JWT] [--resource PAT] [--path PATH] [--amount N]"
      echo "env:   GW AUTHZ TS ID_TOKEN ADMIN_TOKEN RESOURCE REQ_PATH AMOUNT"
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

GW="${GW:-}"; AUTHZ="${AUTHZ:-}"; TS="${TS:-}"
ID_TOKEN="${ID_TOKEN:-}"; ADMIN_TOKEN="${ADMIN_TOKEN:-}"
RESOURCE="${RESOURCE:-/orders}"; REQ_PATH="${REQ_PATH:-/orders}"
AMOUNT="${AMOUNT:-100}"

[ -n "$GW" ]   || { bad "set GW (or --gateway)"; exit 1; }
[ -n "$AUTHZ" ] || { bad "set AUTHZ (or --authz)"; exit 1; }
[ -n "$TS" ]   || { bad "set TS (or --tokensvc)"; exit 1; }
[ -n "$ID_TOKEN" ] || { bad "set ID_TOKEN (or --id-token) — a verified OIDC id token for the delegating human"; exit 1; }
[ -n "$ADMIN_TOKEN" ] || { bad "set ADMIN_TOKEN (or --admin-token) — operator token for revocation"; exit 1; }

# strip trailing slashes
GW="${GW%/}"; AUTHZ="${AUTHZ%/}"; TS="${TS%/}"

SUBJECT=$(printf '%s' "$ID_TOKEN" | cut -d. -f2 2>/dev/null | python3 -c "import sys,json,base64; t=sys.stdin.read().strip(); t+='='*(-len(t)%4); print(json.loads(base64.urlsafe_b64decode(t)).get('sub',''))" 2>/dev/null || true)
[ -n "$SUBJECT" ] && okk "delegating subject: $SUBJECT" || warn "could not decode id_token sub — delegation binding may still work server-side"

# --- helper: create a delegation + mint a token for one agent ----------------
mint_agent() { # agent_id -> sets DELEG_ID, AGENT_TOKEN globals
  local aid="$1"
  local resp
  resp=$(curl -s --max-time 30 -o /tmp/ksr_del.json -w "%{http_code}" -X POST "$AUTHZ/v1/delegations/" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $ID_TOKEN" \
    -d "{\"agent_id\":\"$aid\",\"resources\":[\"$RESOURCE\"],\"actions\":[\"read\",\"create\"],\"expires_in_seconds\":1800,\"id_token\":\"$ID_TOKEN\"}")
  local code="$resp"
  DELEG_ID=$(python3 -c "import sys,json;print(json.load(open('/tmp/ksr_del.json'))['delegation']['id'])" 2>/dev/null || true)
  AGENT_SECRET=$(python3 -c "import sys,json;print(json.load(open('/tmp/ksr_del.json')).get('agent_secret',''))" 2>/dev/null || true)
  [ "$code" = "200" ] || [ "$code" = "201" ] || { bad "delegation for $aid refused (HTTP $code): $(head -c 160 /tmp/ksr_del.json)"; return 1; }
  [ -n "$DELEG_ID" ] && [ -n "$AGENT_SECRET" ] || { bad "delegation for $aid: missing id/secret"; return 1; }

  local mint
  mint=$(curl -s --max-time 30 -o /tmp/ksr_tok.json -w "%{http_code}" -X POST "$TS/token" \
    -H 'Content-Type: application/json' \
    -d "{\"delegation_id\":\"$DELEG_ID\",\"ttl_seconds\":300,\"agent_secret\":\"$AGENT_SECRET\"}")
  local mcode="$mint"
  AGENT_TOKEN=$(python3 -c "import sys,json;print(json.load(open('/tmp/ksr_tok.json')).get('access_token',''))" 2>/dev/null || true)
  [ "$mcode" = "200" ] || { bad "mint for $aid refused (HTTP $mcode): $(head -c 160 /tmp/ksr_tok.json)"; return 1; }
  [ -n "$AGENT_TOKEN" ] || { bad "mint for $aid: no access_token"; return 1; }
  line "  $aid  → delegation $DELEG_ID  → token ${AGENT_TOKEN:0:14}…"
}

# --- helper: one agent calls the gateway path, reports code ------------------
agent_call() { # agent_label token -> code on stdout (diagnostic to stderr)
  local label="$1" tok="$2"
  local code body
  code=$(curl -s --max-time 30 -o /tmp/ksr_body.json -w '%{http_code}' -X POST "$GW$REQ_PATH" \
    -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    -d "{\"amount\":$AMOUNT,\"supplier\":\"acme\"}")
  body=$(cat /tmp/ksr_body.json 2>/dev/null || true)
  local detail=""
  if [ -n "$body" ]; then
    detail=$(printf '%s' "$body" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('reason') or d.get('error') or d.get('status',''))" 2>/dev/null || true)
  fi
  line "  $label: HTTP $code${detail:+: $detail}" >&2
  echo "$code"
}

# --- revoke a delegation -----------------------------------------------------
revoke() { # delegation_id -> code
  curl -s --max-time 30 -o /dev/null -w '%{http_code}' -X DELETE "$AUTHZ/v1/delegations/$1" \
    -H "Authorization: Bearer $ID_TOKEN"
}

# --- 0. health ---------------------------------------------------------------
step "Step 1 — remote service health"
HEALTHY=1
for svc in authz:$AUTHZ tokensvc:$TS gateway:$GW; do
  name="${svc%%:*}"; url="${svc#*:}"
  if curl -sf --max-time 10 "$url/healthz" >/dev/null 2>&1; then
    okk "$name ($url) healthy"
  else
    bad "$name ($url) not healthy"; HEALTHY=0
  fi
done
[ "$HEALTHY" = 1 ] || { bad "one or more remote services unreachable"; exit 1; }

# --- 2. create three agents, one upstream resource ---------------------------
step "Step 2 — three agents, one upstream resource ($RESOURCE), one delegator ($SUBJECT)"
TS_FX=$(date +%s)
mint_agent "purchasing-agent-$TS_FX" || exit 1
DELEG_PURCHASING="$DELEG_ID"; TOKEN_PURCHASING="$AGENT_TOKEN"
mint_agent "shipping-agent-$TS_FX"   || exit 1
DELEG_SHIPPING="$DELEG_ID";   TOKEN_SHIPPING="$AGENT_TOKEN"
mint_agent "billing-agent-$TS_FX"    || exit 1
DELEG_BILLING="$DELEG_ID";    TOKEN_BILLING="$AGENT_TOKEN"

# --- 3. all three agents call — everything allowed ---------------------------
step "Step 3 — before the kill switch: every agent calls $REQ_PATH (expect 200)"
C1=$(agent_call "purchasing-agent" "$TOKEN_PURCHASING")
C2=$(agent_call "shipping-agent"   "$TOKEN_SHIPPING")
C3=$(agent_call "billing-agent"    "$TOKEN_BILLING")
[ "$C1" = "200" ] && [ "$C2" = "200" ] && [ "$C3" = "200" ] || { bad "expected all 200 before kill switch"; exit 1; }
okk "all three agents reach $REQ_PATH — the upstream is open to delegated agents"

# --- 4. KILL SWITCH #1 — ONE agent -------------------------------------------
step "Step 4 — KILL SWITCH #1: revoke shipping-agent's delegation only"
RVC=$(revoke "$DELEG_SHIPPING")
[ "$RVC" = "204" ] || [ "$RVC" = "200" ] || { bad "revoke of shipping-agent failed (HTTP $RVC)"; exit 1; }
okk "shipping-agent delegation revoked (instant, enforced by authz before any engine)"
line "the shipping-agent JWT is still cryptographically valid — but it is no longer authorized"

step "Step 5 — after kill switch #1: shipping-agent cut off, others still work"
S1=$(agent_call "purchasing-agent   (still allowed)" "$TOKEN_PURCHASING")
S2=$(agent_call "shipping-agent     (KILLED)"        "$TOKEN_SHIPPING")
S3=$(agent_call "billing-agent      (still allowed)" "$TOKEN_BILLING")
[ "$S1" = "200" ] && [ "$S3" = "200" ] || { bad "other agents should still reach $REQ_PATH"; exit 1; }
if [ "$S2" = "403" ]; then
  okk "shipping-agent: HTTP 403 — DENIED at enforcement, revocation worked instantly"
else
  bad "shipping-agent expected 403 after revocation, got $S2: $(head -c 160 /tmp/ksr_body.json)"
  exit 1
fi

# --- 5. KILL SWITCH #2 — ALL agents ------------------------------------------
step "Step 6 — KILL SWITCH #2: revoke ALL delegations to $RESOURCE (whole upstream)"
for del in "$DELEG_PURCHASING" "$DELEG_BILLING"; do
  RVC=$(revoke "$del")
  line "  revoked delegation $del (HTTP $RVC)"
done
okk "every delegation to $RESOURCE is now revoked — no agent may reach this upstream"

step "Step 7 — after kill switch #2: every agent is refused at the gateway"
T1=$(agent_call "purchasing-agent   (KILLED)" "$TOKEN_PURCHASING")
T2=$(agent_call "shipping-agent     (KILLED)" "$TOKEN_SHIPPING")
T3=$(agent_call "billing-agent      (KILLED)" "$TOKEN_BILLING")
[ "$T1" = "403" ] && [ "$T2" = "403" ] && [ "$T3" = "403" ] || { bad "expected all 403 after full kill switch"; exit 1; }
okk "all three agents: HTTP 403 — the upstream is closed to every agent"

# --- summary -----------------------------------------------------------------
printf "\n${BLD}Kill-switch demo (remote) complete${RST}\n"
line "Kill switch #1 (one agent):  revoke shipping-agent → valid token → 403"
line "Kill switch #2 (all agents): revoke every $RESOURCE delegation → all agents → 403"
line "Revoke is enforced by authz before any engine runs — it beats token validity,"
line "pending approvals, and any policy file. Nothing reaches the upstream after a kill."
printf "\n  Gateway:  $GW\n"

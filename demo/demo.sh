#!/usr/bin/env bash
# ============================================================================
# Agent Gateway — live end-to-end scripted demo (public demo stack)
#
# Runs the complete authorization story against the running docker compose
# stack: SSO sign-in (Dex), delegation creation, agent token minting,
# auto-allow for low-risk actions, approval hold for high-risk actions,
# human approval, and instant revocation before the agent's eyes.
#
# Prereqs:   cd "$(dirname "$0")" && docker compose up -d
# Usage:     ./demo.sh
# ============================================================================

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

RED=''; GRN=''; YLW=''; BLU=''; BLD=''; RST=''
if [ -t 1 ]; then
  RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; BLU='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
fi

step()  { printf "\n${BLD}${BLU}%s${RST}\n" "$*"; }
okk()   { printf "  ${GRN}✓ %s${RST}\n" "$*"; }
bad()   { printf "  ${RED}✗ %s${RST}\n" "$*"; }
warn()  { printf "  ${YLW}• %s${RST}\n" "$*"; }
line()  { printf "  %s\n" "$*"; }

# Prefer the compose plugin; fall back to the standalone docker-compose binary.
COMPOSE="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  COMPOSE="docker-compose"
fi

# Published PEP port: GATEWAY_HOST_PORT (env or .env) overrides 8080, e.g. when
# a local OpenShell gateway already owns :8080. Compose reads the same .env.
if [ -z "${GATEWAY_HOST_PORT:-}" ] && [ -f "$DEMO_DIR/.env" ]; then
  GATEWAY_HOST_PORT="$(sed -n 's/^GATEWAY_HOST_PORT=//p' "$DEMO_DIR/.env" | tail -1)"
fi
GW=${GW:-http://localhost:${GATEWAY_HOST_PORT:-8080}}
GW_PORT=${GW##*:}

# --- 0. stack & health ------------------------------------------------------
step "Step 1 — services & health"
# Register this machine's console URIs in the dex client first (no-op when
# they are already listed) so browser sign-in never trips
# "Bad Request — Unregistered redirect_uri" on a fresh clone. demo.sh has
# already cd'd into demo/, so the helper is addressed absolutely.
bash "$DEMO_DIR/refresh-dex-redirects.sh" || true
# --no-recreate: start anything missing, but never touch containers that are
# already running — so a stack brought up with an override (e.g.
# docker-compose.opa.yml, which switches authz to the Rego policy engine) is
# not silently reverted to the base config by the demo.
$COMPOSE up -d --no-recreate 2>/dev/null | grep -c "Started\|Running" >/dev/null 2>&1 || true
sleep 2
HEALTHY=1
for port in 8081 8082 "$GW_PORT" 8083; do
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
[ "$HEALTHY" = 1 ] || { bad "unhealthy stack — run: docker compose up -d"; exit 1; }

# --- 1. sign in via SSO (Dex mock connector, one click) ----------------------
step "Step 2 — sign in at the identity provider (SSO)"
DEX="http://localhost:5556"
fixdex() { sed 's|//dex:5556|//localhost:5556|'; }
JAR=$(mktemp)
# Follow the OIDC redirect chain (mock connector = no credentials):
#   /dex/auth → /dex/auth/mock → /dex/callback?state → client callback with code
ID_TOKEN=""
LOC="$DEX/dex/auth?response_type=code&client_id=agent-gateway&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback&connector_id=mock&scope=openid"
CODE=""
for _ in 1 2 3 4 5 6; do
  NX=$(curl -s -b "$JAR" -c "$JAR" -D - -o /dev/null "$LOC" | grep -i '^location' | head -1 | tr -d '\r' | sed 's/^Location: //' | fixdex)
  [ -z "$NX" ] && break
  case "$NX" in
    *code=*) CODE=$(echo "$NX" | sed 's/.*code=\([^&]*\).*/\1/'); break;;
    /*) LOC="$DEX$NX" ;;
    *)  LOC="$NX" ;;
  esac
done
if [ -n "$CODE" ]; then
  ID_TOKEN=$(curl -s -X POST "$DEX/dex/token" \
    -d "grant_type=authorization_code&client_id=agent-gateway&code=$CODE&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('id_token',''))" 2>/dev/null || true)
fi
APPROVER=""
if [ -n "${ID_TOKEN:-}" ]; then
  okk "SSO sign-in succeeded; human identity verified (ID token, ${#ID_TOKEN} chars)"
  APPROVER=$(printf '%s' "$ID_TOKEN" | cut -d. -f2 | python3 -c "import sys,json,base64; t=sys.stdin.read().strip(); t+='='*(-len(t)%4); print(json.loads(base64.urlsafe_b64decode(t)).get('sub',''))" 2>/dev/null || true)
else
  bad "could not complete SSO sign-in — is Dex running with the mock connector?"
  warn "try:  open http://localhost:8083/oidc/login"
  exit 1
fi

# --- 2. delegation: what the agent is allowed to do --------------------------
step "Step 3 — create a delegation (human decision, least privilege)"
DELEGATION=$(curl -s -X POST http://localhost:8081/v1/delegations/ \
  -H "Content-Type: application/json" \
  -d "{\"agent_id\":\"purchasing-agent-42\",\"resources\":[\"/orders\"],\"actions\":[\"read\",\"create\"],\
\"expires_in_seconds\":1800,\"limits\":{\"spend_per_order\":{\"type\":\"currency\",\"max\":200,\"unit\":\"EUR\"}},\
\"id_token\":\"$ID_TOKEN\"}")
DELEGATION_ID=$(printf '%s' "$DELEGATION" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['delegation']['id'])" 2>/dev/null || true)
AGENT_SECRET=$(printf '%s' "$DELEGATION" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agent_secret',''))" 2>/dev/null || true)
if [ -n "$DELEGATION_ID" ]; then
  okk "delegation created:  $DELEGATION_ID (mint credential issued to the agent)"
  line "scope: /orders [read, create] · auto-approve ≤ €200 · bound to the SSO subject"
else
  bad "delegation refused:  $(printf '%s' "$DELEGATION" | head -c 200)"
  exit 1
fi

# --- 3. the agent exchanges its delegation for a short-lived token ------------
step "Step 4 — agent mints a short-lived token"
AGENT_TOKEN=$(curl -s -X POST http://localhost:8082/token \
  -H "Content-Type: application/json" \
  -d "{\"delegation_id\":\"$DELEGATION_ID\",\"ttl_seconds\":300,\"agent_secret\":\"$AGENT_SECRET\"}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token') or d.get('token',''))" 2>/dev/null || true)
if [ -n "$AGENT_TOKEN" ]; then
  okk "agent token issued (${#AGENT_TOKEN} chars, ttl 5 minutes)"
  line "it embeds subject + agent id + delegation id; jti enables instant revocation"
else
  bad "mint failed"
  exit 1
fi

# --- 4. low-risk action: auto-allow -----------------------------------------
step "Step 5 — agent acts: €150 order  (auto-allow ≤ €200)"
CODE150=$(curl -s -o /tmp/demo_low.json -w "%{http_code}" -X POST $GW/orders \
  -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
  -d '{"amount":150,"supplier":"acme"}')
if [ "$CODE150" = "200" ]; then
  okk "HTTP 200 — executed automatically, no human in the loop"
  line "forwarded upstream and written to the audit trail"
else
  bad "HTTP $CODE150 (expected 200):  $(head -c 200 /tmp/demo_low.json)"
fi

# --- 5. high-risk action: held for approval ---------------------------------
step "Step 6 — agent acts: €250 order  (above cap → approval required)"
HIGH=$(curl -s -X POST $GW/orders \
  -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
  -d '{"amount":250,"supplier":"acme"}')
APPROVAL_ID=$(printf '%s' "$HIGH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('approval_id',''))" 2>/dev/null || true)
if [ -n "$APPROVAL_ID" ]; then
  okk "HTTP 202 — order HELD, nothing executed"
  line "approval_id:  $APPROVAL_ID"
  line "bound to the exact action hash; money has not moved"
else
  bad "expected 202 + approval_id, got:  $(printf '%s' "$HIGH" | head -c 200)"
fi

# --- 6. human approves -------------------------------------------------------
step "Step 7 — you decide: approve the €250 order"
# The gateway binds the decision to the delegating user: approver_id must be
# the SSO subject the delegation was created with (APPROVAL_ENFORCE_APPROVER).
DEC=$(curl -s -o /tmp/demo_appr.json -w "%{http_code}" -X POST $GW/v1/approvals/ \
  -H "Content-Type: application/json" \
  -H "X-Admin-Token: ${ADMIN_TOKEN:-agent-gateway-demo-admin}" \
  -d "{\"approval_id\":\"$APPROVAL_ID\",\"approver_id\":\"$APPROVER\",\"approved\":true}")
if [ "$DEC" = "200" ]; then
  okk "approval granted (single-use, action-specific)"
else
  bad "approval failed (HTTP $DEC):  $(head -c 200 /tmp/demo_appr.json)"
fi

# --- 7. retry succeeds ------------------------------------------------------
step "Step 8 — the agent retries the €250 order"
CODE250=$(curl -s -o /tmp/demo_retry.json -w "%{http_code}" -X POST $GW/orders \
  -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
  -d '{"amount":250,"supplier":"acme"}')
if [ "$CODE250" = "200" ]; then
  okk "HTTP 200 — executed exactly once, human decision on the record"
else
  bad "HTTP $CODE250 (expected 200):  $(head -c 200 /tmp/demo_retry.json)"
fi

# --- 8. instant revocation ---------------------------------------------------
step "Step 9 — revoke the delegation (instant enforcement)"
RVC=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "http://localhost:8081/v1/delegations/$DELEGATION_ID")
if [ "$RVC" = "204" ] || [ "$RVC" = "200" ]; then
  okk "delegation revoked — even though the token is still cryptographically valid"
  DENY=$(curl -s -o /tmp/demo_deny.json -w "%{http_code}" -X POST $GW/orders \
    -H "Authorization: Bearer $AGENT_TOKEN" -H "Content-Type: application/json" \
    -d '{"amount":150,"supplier":"acme"}')
  if [ "$DENY" = "403" ]; then
    okk "next agent action: HTTP 403 — DENIED at enforcement, revocation worked instantly"
  else
    bad "expected 403 after revocation, got $DENY:  $(head -c 200 /tmp/demo_deny.json)"
  fi
else
  bad "revoke failed (HTTP $RVC)"
fi

printf "\n${BLD}Demo summary${RST}\n"
line "SSO sign-in  → delegation (human decision) → short-lived agent token"
line "low-risk action auto-allowed · high-risk action held for approval"
line "single-use human approval · immediate revocation beats valid tokens"
printf "\n${BLD}Explore further${RST}\n"
line "Web console:  http://localhost:8083            (delegations / approvals / audit)"
line "Graphical guided demo (same stack, visual):  http://localhost:8083/demo.html"
# The OPA policy playground only has something to show when the stack was
# brought up with the policy override (docker-compose.opa.yml), so only mention
# it when the web tier reports a live policy file.
if curl -sf http://localhost:8083/api/policy 2>/dev/null | grep -q '"available":true'; then
  line "OPA policy playground (edit the live policy):  http://localhost:8083/policy.html"
fi
line "Stop everything when finished:  docker compose down"

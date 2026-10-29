#!/usr/bin/env bash
# ============================================================================
# Demo — Approval edge cases (R&D pilot): expiry, action-change binding,
# single-use, and the audit trail for decisions + executed calls.
#
# Story: an agent attempts a high-risk action (/orders, €250) that the gateway
# holds for human approval. We exercise three situations:
#
#   1. Approval arrives AFTER expiry  → 410 Gone, nothing executed, fresh hold
#   2. Action details changed (amount)  → new action hash → fresh hold required
#   3. No silent resurrection           → denied/expired never executes without
#                                          a fresh human decision
#
# Assert the audit trail for this delegation: holds, denied retries and executed
# calls, with approval/approver correlation. Decisions alone do not execute calls.
#
# Prereqs:   cd demo && APPROVAL_TTL=10s docker compose up -d
# Usage:     ./demo/approval-edge-cases-demo.sh
# ============================================================================
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Container engine (docker or podman), same convention as the rest of the repo.
source ./lib/engine.sh

RED=''; GRN=''; YLW=''; CYN=''; BLD=''; RST=''
if [ -t 1 ]; then
  RED=$(printf '\033[0;31m'); GRN=$(printf '\033[0;32m'); YLW=$(printf '\033[0;33m')
  CYN=$(printf '\033[0;36m'); BLD=$(printf '\033[1m'); RST=$(printf '\033[0m')
fi
step()  { printf '\n%s== %s%s\n' "$CYN" "$*" "$RST"; }
okk()   { printf "  ${GRN}✓ %s${RST}\n" "$*"; }
bad()   { printf "  ${RED}✗ %s${RST}\n" "$*"; }
fail()  { bad "$*"; exit 1; }

GW=${GW:-http://localhost:${GATEWAY_HOST_PORT:-8080}}
AUTHZ=${AUTHZ:-http://localhost:8081}
TS=${TS:-http://localhost:8082}
WEB=${WEB:-http://localhost:8083}
DEX=${DEX:-http://localhost:5556}
ADMIN_TOKEN=${ADMIN_TOKEN:-agent-gateway-demo-admin}
APPROVAL_WAIT=${APPROVAL_WAIT:-60}
AGENT_ID=${AGENT_ID:-rnd-agent-1}

# Dex may advertise its callback on the internal Docker name (dex:5556);
# rewrite to localhost so the host can follow the redirect.
fixdex() { sed 's|//dex:5556|//localhost:5556|'; }

# --- 0. stack & health -------------------------------------------------------
step "0. services & health"
for u in "$GW" "$AUTHZ" "$TS" "$WEB"; do
  curl -sf --max-time 5 "$u/healthz" >/dev/null \
    || fail "service unhealthy: $u — start the stack: APPROVAL_TTL=10s $ENGINE compose up -d"
done
if ! curl -sf --max-time 5 "$DEX/dex/.well-known/openid-configuration" >/dev/null 2>&1; then
  fail "SSO (Dex) on :5556 not responding — start the stack"
fi
okk "gateway · authz · tokensvc · console · dex all healthy"

# --- 1. SSO sign-in (Dex mock connector) → verified subject ------------------
step "1. SSO sign-in (mock connector) → verified subject"
JAR=$(mktemp)
trap 'rm -f "$JAR"' EXIT
LOC="$DEX/dex/auth?response_type=code&client_id=agent-gateway&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback&connector_id=mock&scope=openid"
CODE=""
for _ in 1 2 3 4 5 6; do
  NX=$(curl -s -b "$JAR" -c "$JAR" -D - -o /dev/null "$LOC" | grep -i '^location' | head -1 | tr -d '\r' | sed 's/^Location: //' | fixdex)
  [ -z "$NX" ] && break
  case "$NX" in
    *code=*) CODE=$(echo "$NX" | sed 's/.*code=\([^&]*\).*/\1/'); break ;;
    /*)      LOC="$DEX$NX" ;;
    *)       LOC="$NX" ;;
  esac
done
[ -n "$CODE" ] || fail "SSO redirect chain did not produce a code"
ID_TOKEN=$(curl -s -X POST "$DEX/dex/token" \
  -d "grant_type=authorization_code&client_id=agent-gateway&code=$CODE&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('id_token',''))" 2>/dev/null || true)
[ -n "$ID_TOKEN" ] || fail "could not exchange code for ID token"
SUBJECT=$(printf '%s' "$ID_TOKEN" | cut -d. -f2 | python3 -c "import sys,json,base64; t=sys.stdin.read().strip(); t+='='*(-len(t)%4); print(json.loads(base64.urlsafe_b64decode(t)).get('sub',''))" 2>/dev/null || true)
[ -n "$SUBJECT" ] || fail "no verified subject in ID token"
okk "SSO sign-in succeeded; subject = $SUBJECT"

# --- helpers -----------------------------------------------------------------
api() { curl -s --max-time 8 "$@"; }
pep() { curl -s --max-time 20 "$@"; }
info() { printf "  ${YLW}• %s${RST}\n" "$*"; }

order_attempt() { # amount supplier → sets ORDER_CODE / ORDER_BODY
  local out
  out=$(pep -X POST "$GW/orders" \
    -H "Authorization: Bearer $AGENT_TOKEN" \
    -H 'Content-Type: application/json' \
    -d "{\"amount\":$1,\"supplier\":\"$2\"}" -w '\n%{http_code}')
  ORDER_CODE=$(printf '%s' "$out" | tail -1 | tr -d '[:space:]')
  ORDER_BODY=$(printf '%s' "$out" | sed '$d')
}

approve() { # approval_id approved(true/false) → HTTP code
  pep -o /dev/null -w '%{http_code}' -X POST "$GW/v1/approvals/" \
    -H 'Content-Type: application/json' -H "X-Admin-Token: $ADMIN_TOKEN" \
    -d "{\"approval_id\":\"$1\",\"approver_id\":\"$SUBJECT\",\"approved\":$2}"
}

held_id() { printf '%s' "$ORDER_BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["approval_id"])'; }

expect_order() {
  [ "$ORDER_CODE" = "$1" ] || fail "expected HTTP $1, got $ORDER_CODE: $ORDER_BODY"
}

executed_count() {
  printf '%s' "$ORDER_BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["executed_count"])'
}

# --- 2. delegation: human grants /orders read+create, approval required ------
step "2. delegation (human decision, least privilege, approval on /orders)"
DELEG_RESP=$(api -X POST "$AUTHZ/v1/delegations/" \
  -H 'Content-Type: application/json' \
  -d "{\"id_token\":\"$ID_TOKEN\",\"agent_id\":\"$AGENT_ID\",\"resources\":[\"/orders\"],\"actions\":[\"read\",\"create\"],\
\"expires_in_seconds\":3600,\"limits\":{\"spend_per_order\":{\"type\":\"currency\",\"max\":200,\"unit\":\"EUR\"}}}")
DELEGATION_ID=$(printf '%s' "$DELEG_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['delegation']['id'])" 2>/dev/null || true)
AGENT_SECRET=$(printf '%s' "$DELEG_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agent_secret',''))" 2>/dev/null || true)
[ -n "$DELEGATION_ID" ] && [ -n "$AGENT_SECRET" ] || fail "delegation creation failed: $(printf '%s' "$DELEG_RESP" | head -c 200)"
okk "delegation: $DELEGATION_ID (POST /orders held for human; ≤€200 auto-allowed)"

# --- 3. agent mints a short-lived token --------------------------------------
step "3. agent mints a short-lived token"
AGENT_TOKEN=$(api -X POST "$TS/token" \
  -H 'Content-Type: application/json' \
  -d "{\"delegation_id\":\"$DELEGATION_ID\",\"ttl_seconds\":300,\"agent_secret\":\"$AGENT_SECRET\"}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token') or d.get('token',''))" 2>/dev/null || true)
[ -n "$AGENT_TOKEN" ] || fail "token mint failed"
okk "agent token issued"
BASELINE=$(pep "$GW/orders" -H "Authorization: Bearer $AGENT_TOKEN" | python3 -c 'import json,sys; print(json.load(sys.stdin)["executed_count"])')

# --- 4. Scenario 1: approval arrives AFTER expiry ---------------------------
step "4. Scenario 1 — approval arrives after expiry (410, nothing executed)"
order_attempt 250 acme
if [ "$ORDER_CODE" != "202" ]; then
  fail "expected first order to be HELD (202), got $ORDER_CODE: $ORDER_BODY"
fi
APR_EXP=$(printf '%s' "$ORDER_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('approval_id',''))" 2>/dev/null || true)
[ -n "$APR_EXP" ] || fail "held (202) but no approval_id"
okk "order held — 202, approval $APR_EXP, upstream not called"

# Use the real store-assigned expiry, without mutating database internals.
WAIT=$(curl -fsS --max-time 8 "$GW/v1/approvals/" -H "X-Admin-Token: $ADMIN_TOKEN" | python3 -c '
import datetime, json, math, sys
row = next(r for r in json.load(sys.stdin) if r["id"] == sys.argv[1])
expiry = datetime.datetime.fromisoformat(row["expires_at"].replace("Z", "+00:00"))
print(max(1, math.ceil((expiry - datetime.datetime.now(datetime.timezone.utc)).total_seconds()) + 1))
' "$APR_EXP")
[ "$WAIT" -le "$APPROVAL_WAIT" ] || fail "approval expires in ${WAIT}s; recreate gateway with APPROVAL_TTL=10s (or increase APPROVAL_WAIT)"
info "waiting ${WAIT}s for the real approval TTL…"
sleep "$WAIT"

# Attempt to approve the expired approval → expect 410 Gone.
DEC=$(approve "$APR_EXP" true)
if [ "$DEC" != "410" ]; then
  fail "expected 410 'approval expired' for post-expiry decision, got $DEC"
fi
okk "post-expiry approval → HTTP 410 Gone (decision refused, nothing executed)"

# Retry the identical order → fresh hold (new approval_id), not silent allow.
order_attempt 250 acme
if [ "$ORDER_CODE" != "202" ]; then
  fail "expected fresh hold (202) after expiry, got $ORDER_CODE: $ORDER_BODY"
fi
APR_FRESH=$(printf '%s' "$ORDER_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('approval_id',''))" 2>/dev/null || true)
[ -n "$APR_FRESH" ] || fail "fresh hold (202) but no approval_id"
[ "$APR_FRESH" != "$APR_EXP" ] || fail "fresh approval_id must differ from the expired one"
okk "retry after expiry → fresh 202 hold, approval $APR_FRESH (new id, nothing executed)"

# Approve the fresh hold, then retry to execute (the decision does not execute).
DEC=$(approve "$APR_FRESH" true)
if [ "$DEC" != "200" ]; then
  fail "expected 200 for fresh approval, got $DEC"
fi
okk "fresh approval granted → HTTP 200"
order_attempt 250 acme
expect_order 200
COUNT_FIRST=$(executed_count)
[ "$COUNT_FIRST" -eq "$((BASELINE + 1))" ] || fail "expired or held actions reached upstream"
okk "exact approved action retried → HTTP 200, upstream count $COUNT_FIRST"

# Retry once more → single-use, must hold again (202), not execute.
order_attempt 250 acme
if [ "$ORDER_CODE" != "202" ]; then
  fail "expected single-use re-hold (202), got $ORDER_CODE: $ORDER_BODY"
fi
okk "single-use: replay after consume → 202 (fresh hold required)"

# --- 5. Scenario 2: action changed (amount 250 → 500) ----------------------
step "5. Scenario 2 — action changed (amount 250→500): new action hash"
# Leave the €250 approval unconsumed while trying the changed €500 action.
APR_S2=$(held_id)
DEC=$(approve "$APR_S2" true)
[ "$DEC" = "200" ] || fail "scenario-2 setup approval failed (HTTP $DEC)"
order_attempt 500 acme
if [ "$ORDER_CODE" != "202" ]; then
  fail "expected changed-amount hold (202), got $ORDER_CODE: $ORDER_BODY"
fi
APR_S2B=$(printf '%s' "$ORDER_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('approval_id',''))" 2>/dev/null || true)
[ -n "$APR_S2B" ] || fail "changed amount held (202) but no approval_id"
[ "$APR_S2B" != "$APR_S2" ] || fail "changed amount reused original approval"
okk "changed amount (500) → 202, approval $APR_S2B (different action hash from €250)"

# Approve and retry the changed action, then prove the original approval remains usable.
DEC=$(approve "$APR_S2B" true)
if [ "$DEC" != "200" ]; then
  fail "expected 200 for changed-amount approval, got $DEC"
fi
okk "changed-amount approval granted → HTTP 200"
order_attempt 500 acme
expect_order 200
COUNT_CHANGED=$(executed_count)
[ "$COUNT_CHANGED" -eq "$((COUNT_FIRST + 1))" ] || fail "held/replayed actions reached upstream"
order_attempt 250 acme
expect_order 200
COUNT_ORIGINAL=$(executed_count)
[ "$COUNT_ORIGINAL" -eq "$((COUNT_CHANGED + 1))" ] || fail "unexpected upstream execution count"
okk "different action required its own decision; original approval still authorized only €250"

# --- 6. Scenario 3: no silent resurrection ----------------------------------
step "6. Scenario 3 — no silent resurrection (denied/expired never executes)"
order_attempt 250 acme
if [ "$ORDER_CODE" != "202" ]; then
  fail "expected hold (202), got $ORDER_CODE: $ORDER_BODY"
fi
APR_S3=$(printf '%s' "$ORDER_BODY" | python3 -c "import sys,json; print(json.load(sys.stdin).get('approval_id',''))" 2>/dev/null || true)
[ -n "$APR_S3" ] || fail "held (202) but no approval_id"

# Deny it.
DEC=$(approve "$APR_S3" false)
if [ "$DEC" != "200" ]; then
  fail "expected deny to succeed (HTTP 200), got $DEC"
fi
okk "denial recorded (HTTP 200)"

# Retry the identical denied order → must hold again (202) or be 403, never 200.
order_attempt 250 acme
case "$ORDER_CODE" in
  202) okk "retry after denial → 202 (fresh hold, not executed)" ;;
  403) okk "retry after denial → 403 (decision binds the action)" ;;
  *)   fail "retry after denial must not execute — got $ORDER_CODE: $ORDER_BODY" ;;
esac
[ "$ORDER_CODE" != "200" ] || fail "denied action must never execute without a fresh decision"

# --- 7. Audit trail assertions ----------------------------------------------
step "7. audit trail (only this run's delegation)"
# An auto-allowed read gives the final upstream count without executing another order.
OUT=$(pep "$GW/orders" -H "Authorization: Bearer $AGENT_TOKEN")
COUNT_END=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["executed_count"])')
[ "$COUNT_END" -eq "$((COUNT_ORIGINAL + 1))" ] || fail "denied action reached upstream"
curl -fsS --max-time 8 "$GW/v1/audit/?delegation_id=$DELEGATION_ID&limit=100" \
  -H "X-Admin-Token: $ADMIN_TOKEN" | python3 -c '
import json, sys
events = json.load(sys.stdin)["events"]
delegation, agent, subject, expired, fresh, original, changed, denied = sys.argv[1:]
assert events, "no audit events for this delegation"
assert all(e.get("delegation_id") == delegation and e.get("agent_id") == agent and e.get("user_id") == subject for e in events), "missing actor attribution"
holds = {e.get("approval_id") for e in events if e["outcome"] == "approval_required"}
assert {expired, fresh, original, changed, denied} <= holds, "missing hold events"
allows = [e for e in events if e["outcome"] == "allow" and e["action"] == "create"]
assert len(allows) == 3, "expected exactly three approved executions"
assert {e.get("approval_id") for e in allows} == {fresh, original, changed}, "wrong approval consumed"
assert all(e.get("approver_id") == subject and e.get("status_code") == 200 for e in allows), "missing execution/approver evidence"
assert any(e["outcome"] == "deny" and e.get("approval_id") == denied and e.get("approver_id") == subject for e in events), "missing denied retry"
print("  ✓ audit: holds, three executed calls and denial correlated to this human/agent/delegation")
' "$DELEGATION_ID" "$AGENT_ID" "$SUBJECT" "$APR_EXP" "$APR_FRESH" "$APR_S2" "$APR_S2B" "$APR_S3"

# --- 8. cleanup: revoke delegation ------------------------------------------
step "8. revoke delegation (instant enforcement)"
RVC=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$AUTHZ/v1/delegations/$DELEGATION_ID" \
  -H "Authorization: Bearer $ID_TOKEN")
if [ "$RVC" = "204" ] || [ "$RVC" = "200" ]; then
  okk "delegation revoked"
  order_attempt 150 acme
  if [ "$ORDER_CODE" = "403" ]; then
    okk "after revoke: HTTP 403 — instant enforcement"
  else
    fail "after revoke expected 403, got $ORDER_CODE"
  fi
else
  fail "revoke failed (HTTP $RVC)"
fi

printf '\n%s%s%s\n' "$CYN" "─────────────────────────────────────────────────────────────────────────" "$RST"
printf 'R&D pilot result: approvals are action-bound, expire, and are audited.\n'
printf '  • post-expiry decision → 410 Gone, nothing executed\n'
printf '  • changed action details → new action hash → fresh hold required\n'
printf '  • denied/expired → never silently resurrected (202 hold or 403)\n'
printf '  • audit records every hold decision and every executed call\n'
printf '%sPASS%s\n' "$GRN" "$RST"

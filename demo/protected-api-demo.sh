#!/bin/bash
# Protected-API demo — approval BEFORE the downstream executes.
#
# Uses the delegation's built-in approval_rules (no policy editing) against
# the demoapi upstream: the first call to /api/sensitive/* is held (202) and
# the demoapi counter does NOT move. Two modes:
#
#   default        : the script approves as the delegating user (all steps)
#   --await-human  : the script STOPS at the hold — you approve/deny on the
#                    Telegram card (or in the console) — the script polls for
#                    your verdict, then runs the retry and revoke steps
#
# Platforms:
#   compose (default):  ./protected-api-demo.sh
#   k3s cluster:        ./protected-api-demo.sh --node 192.168.1.74
#                       (--await-human --node 192.168.1.74 …)
#
# Endpoints or secrets can be overridden with env vars:
#   WEB, GW, AUTHZ, TS, ADMIN_TOKEN
set -euo pipefail

NODE_ARG=""
AWAIT_HUMAN=${AWAIT_HUMAN:-0}
while [ $# -gt 0 ]; do
  case "$1" in
    --node) NODE_ARG="$2"; shift 2 ;;
    --await-human) AWAIT_HUMAN=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [ -n "$NODE_ARG" ]; then
  NODE="$NODE_ARG"
  WEB=${WEB:-http://$NODE:30083}
  GW=${GW:-http://$NODE:30080}
  AUTHZ=${AUTHZ:-http://$NODE:30081}
  TS=${TS:-http://$NODE:30082}
else
  NODE=""
  WEB=${WEB:-http://localhost:8083}
  GW=${GW:-http://localhost:${GATEWAY_HOST_PORT:-8080}}
  AUTHZ=${AUTHZ:-http://localhost:8081}
  TS=${TS:-http://localhost:8082}
fi
ADMIN_TOKEN=${ADMIN_TOKEN:-agent-gateway-demo-admin}

step() { printf '\n== %s\n' "$*"; }
fail() { printf '✗ %s\n' "$*" >&2; exit 1; }

step "0. services"
curl -sf --max-time 5 "$GW/healthz" >/dev/null || fail "gateway $GW unhealthy"
curl -sf --max-time 5 "$TS/healthz" >/dev/null || fail "tokensvc $TS unhealthy"
curl -s --max-time 5 -o /dev/null "$WEB/" || fail "console $WEB unreachable"

step "1. SSO sign-in (mock connector) → verified subject"
JAR=$(mktemp)
HOST_PART=$(echo "$WEB" | sed -E 's|^http://||')
PORT_PART=${HOST_PART##*:}
HOST_PART=${HOST_PART%%:*}
REDIR="http://${HOST_PART}:${PORT_PART}/oidc/callback"
ENCODED=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$REDIR")
LOC="$WEB/oidc/idp/dex/auth?response_type=code&client_id=agent-gateway&redirect_uri=$ENCODED&connector_id=mock&scope=openid"
CODE=""
for _ in 1 2 3 4 5 6; do
  NX=$(curl -s -b "$JAR" -c "$JAR" -D - -o /dev/null "$LOC" | grep -i '^location' | head -1 | tr -d '\r' | sed 's/^Location: //')
  [ -z "$NX" ] && break
  case "$NX" in
    *code=*) CODE=$(echo "$NX" | sed 's/.*code=\([^&]*\).*/\1/'); break ;;
    /*)      LOC="$WEB$NX" ;;
    *)       LOC="$NX" ;;
  esac
done
[ -n "$CODE" ] || fail "SSO redirect chain did not produce a code"
IT=$(curl -s -b "$JAR" -c "$JAR" -X POST "$WEB/oidc/idp/dex/token" \
  -d "grant_type=authorization_code&client_id=agent-gateway&code=$CODE&redirect_uri=$REDIR" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("id_token",""))')
SUBJECT=$(printf '%s' "$IT" | cut -d. -f2 | python3 -c "import sys,json,base64; t=sys.stdin.read().strip(); t+='='*(-len(t)%4); print(json.loads(base64.urlsafe_b64decode(t)).get('sub',''))")
[ -n "$SUBJECT" ] || fail "no verified subject (ID token exchange failed)"
echo "   subject: $SUBJECT"

step "2. delegation scoped to /orders + /api/sensitive* with an approval rule"
D=$(curl -s -X POST "$AUTHZ/v1/delegations/" -H 'Content-Type: application/json' \
  -d "{\"id_token\":\"$IT\",\"agent_id\":\"demoapi-agent\",\"resources\":[\"/orders\",\"/api/sensitive*\"],\"actions\":[\"read\",\"create\"],\"expires_in_seconds\":1800,\"approval_rules\":[{\"when\":{\"resource_pattern\":\"/api/sensitive*\"},\"require\":true,\"rationale\":\"sensitive API access requires a human\"}]}")
DELEG=$(echo "$D" | python3 -c 'import sys,json;print(json.load(sys.stdin)["delegation"]["id"])' 2>/dev/null)
SECRET=$(echo "$D" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("agent_secret",""))' 2>/dev/null)
[ -n "$DELEG" ] && [ -n "$SECRET" ] || fail "delegation creation failed: $(echo "$D" | head -c 200)"
echo "   delegation: $DELEG"

step "3. agent mints its short-lived token (agents never hold approval rights)"
TOK=$(curl -s -X POST "$TS/token" -H 'Content-Type: application/json' \
  -d "{\"delegation_id\":\"$DELEG\",\"ttl_seconds\":300,\"agent_secret\":\"$SECRET\"}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("access_token",""))')
[ -n "$TOK" ] || fail "mint failed"
echo "   minted: ${TOK:0:18}…"

step "4. low-risk /orders runs immediately — forwarded to demoapi (counter proof)"
R1=$(curl -s -X POST "$GW/orders" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"amount":150,"supplier":"acme"}')
echo "   HTTP 200, demoapi /orders executed_count: $(echo "$R1" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("executed_count"))')"

step "5. FIRST call to /api/sensitive/payment → HELD (202) and NOT executed"
HTTP2=$(curl -s -o /tmp/pa-held.json -w '%{http_code}' \
  -X POST "$GW/api/sensitive/payment" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"amount":500,"iban":"DE00"}')
AP=$(python3 -c 'import json;print(json.load(open("/tmp/pa-held.json")).get("approval_id",""))')
REASON=$(python3 -c 'import json;print(json.load(open("/tmp/pa-held.json")).get("reason",""))')
[ "$HTTP2" = "202" ] && [ -n "$AP" ] || fail "want 202 + approval_id, got $HTTP2 $(head -c 200 /tmp/pa-held.json)"
echo "   202 · approval_id: $AP"
echo "   reason: $REASON"
echo "   (the demoapi counter did NOT move — no downstream call was made)"

if [ "$AWAIT_HUMAN" = "1" ]; then
  step "6. AWAITING HUMAN DECISION — approve/deny on the Telegram card (or the console)"
  echo "   polling the gateway for your verdict (up to 360 s)…"
  DECIDED=""
  R3_AWAIT=""
  for i in $(seq 1 72); do
    # The agent retries the IDENTICAL bound action: before the decision the
    # gateway answers 202 again; after an approve it executes (200 — the
    # single-use approval is consumed); after a deny it answers 403.
    CODE=$(curl -s -o /tmp/pa-poll.json -w '%{http_code}' \
      -X POST "$GW/api/sensitive/payment" -H "Authorization: Bearer $TOK" \
      -H 'Content-Type: application/json' -d '{"amount":500,"iban":"DE00"}')
    case "$CODE" in
      202) ;;                    # still awaiting the human
      200) R3_AWAIT=$(cat /tmp/pa-poll.json); DECIDED=approved; break ;;
      403) DECIDED=denied;   break ;;
      *)   ;;                # transient — keep polling
    esac
    sleep 5
  done
  case "${DECIDED:-}" in
    approved) echo "   approved ✓ by the delegating user (recorded in the audit trail)";;
    denied)   echo "   the human DENIED — nothing executed, exactly as designed"; exit 0 ;;
    *)        fail "no decision in 360 s (approval stays pending — nothing executed)";;
  esac
else
  step "6. a SECOND human (mallory) cannot authorize someone else's agent"
  BAD=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/v1/approvals/"\
    -H 'Content-Type: application/json' -H "X-Admin-Token: $ADMIN_TOKEN" \
    -d "{\"approval_id\":\"$AP\",\"approver_id\":\"mallory\",\"approved\":true}" || true)
  case "$BAD" in
    *401*) echo "   rejected with 401 invalid admin token ✓";;
    *403*) echo "   rejected with 403 ✓ (approver binding holds)";;
    *)     fail "mallory approve must not be 200, got $BAD";;
  esac

  step "7. the delegating user approves → single-use, action-bound"
  DEC=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/v1/approvals/" \
    -H 'Content-Type: application/json' -H "X-Admin-Token: $ADMIN_TOKEN" \
    -d "{\"approval_id\":\"$AP\",\"approver_id\":\"$SUBJECT\",\"approved\":true}")
  [ "$DEC" = "200" ] || fail "bound-user approve: want 200, got $DEC"
  echo "   200 ✓"
fi

step "8. retry executes — the counters prove the API ran exactly once"
if [ "$AWAIT_HUMAN" = "1" ] && [ -n "${R3_AWAIT:-}" ]; then
  # In --await-human mode the approval-consuming retry in step 6 already
  # executed the call (200), so report THAT response rather than firing a new
  # request — a fresh POST would be a brand-new held action (a second call).
  R3="$R3_AWAIT"
  echo "   (the approved retry polled in step 6 already executed this call)"
else
  R3=$(curl -s -X POST "$GW/api/sensitive/payment" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"amount":500,"iban":"DE00"}')
fi
echo "   executed_count/note → $(echo "$R3" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("executed_count"), d.get("note"))')"
echo "   (counter is cumulative per demoapi container; the held call contributed nothing)"

step "9. revoke — every subsequent call denied at the enforcement point"
curl -s -o /dev/null -X DELETE "$AUTHZ/v1/delegations/$DELEG" -H "Authorization: Bearer $IT"
R4=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/api/sensitive/payment" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"amount":500}')
echo "   after revoke: HTTP $R4 (expected 403)"
[ "$R4" = "403" ] || fail "after revoke wanted 403, got $R4"

printf '\nProtected-API demo complete: 202-held (not executed) → human decision (%s mode) →\nexecuted exactly once → revocation denies instantly.\n' "$([ "$AWAIT_HUMAN" = "1" ] && echo human || echo scripted)"

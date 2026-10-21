#!/usr/bin/env bash
# ============================================================================
# Agent Gateway — LIVE DEMO 5: every outbound call via the gateway, with
# human approval on each one (OpenShell-style egress enforcement)
#
# Requires the gateway egress proxy listener (images >= gateway 1.0.22):
#     GATEWAY_PROXY_ADDR=:8088   (+ published port 8088)
# Enable it with the committed overlay:
#     compose -f docker-compose.yml -f docker-compose.egress.yml up -d
# ============================================================================
if [ -z "${BASH_VERSION:-}" ]; then
  echo "this script must run under BASH — the way it was invoked bypassed the" >&2
  echo "shebang (e.g. 'zsh ./egress-demo.sh' or sourcing it), and bash constructs" >&2
  echo "are not valid zsh syntax (typical symptom: 'zsh: number expected')." >&2
  echo "Run it as:  bash ./egress-demo.sh   (or: chmod +x ./egress-demo.sh; ./egress-demo.sh)" >&2
  exit 64
fi
#
# The story, inTraffic terms:
#   SSO sign-in → delegation for egress (hosts, not tool paths) → agent token
#   → an outbound call HELD for human approval → approve → executed once
#   → undelegated host denied by policy → TLS CONNECT held/approved/denied
#   → revocation closes the door instantly.
#
# Every proxied request carries the audit fields the tool path has
# (alice / agent / delegation / why permitted) — nothing is black-box.
#
# Note on OpenShell: when an NVIDIA OpenShell sandbox is the *player*,
# its supervisor speaks the proxy auth and the sandbox processes never see
# credentials (see OpenShell-Integration.md in the agent-gateway repo). This
# demo uses curl to expose the same call points a sandbox makes.
# ============================================================================

set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED=''; GRN=''; YLW=''; BLU=''; BLD=''; RST=''
if [ -t 1 ]; then
  RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; BLU='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
fi
step()  { printf "\n${BLD}${BLU}%s${RST}\n" "$*"; }
okk()   { printf "  ${GRN}✓ %s${RST}\n" "$*"; }
bad()   { printf "  ${RED}✗ %s${RST}\n" "$*"; }
warn()  { printf "  ${YLW}• %s${RST}\n" "$*"; }
line()  { printf "  %s\n" "$*"; }

# Docker or Podman — see lib/engine.sh (CONTAINER_ENGINE env override).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/engine.sh"

PROXY_URL="http://localhost:8088"
PROXY_HOST="${PROXY_URL#*//}"; PROXY_HOST="${PROXY_HOST%%:*}"
PROXY_PORT="${PROXY_URL##*:}"
# Published PEP port: GATEWAY_HOST_PORT (env or .env) overrides 8080, e.g. when
# a local OpenShell gateway already owns :8080.
if [ -z "${GATEWAY_HOST_PORT:-}" ] && [ -f .env ]; then
  GATEWAY_HOST_PORT="$(sed -n 's/^GATEWAY_HOST_PORT=//p' .env | tail -1)"
fi
GW=${GW:-http://localhost:${GATEWAY_HOST_PORT:-8080}}
GW_PORT=${GW##*:}
ADMIN_TOKEN="${ADMIN_TOKEN:-agent-gateway-demo-admin}"
HOST_ALLOW="example.com"
HOST_DENY="nuiance.example.net"

# --- 0. stack & health -------------------------------------------------------
step "Step 1 — services & health (incl. the egress proxy)"
compose up -d --no-recreate >/dev/null 2>&1 || true
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
  okk "gateway egress proxy on :$PROXY_URL — unauthenticated requests refused (407), never proxied"
else
  bad "egress proxy posture unexpected: ${POSTURE} (want 407)"
  warn "is GATEWAY_PROXY_ADDR=:8088 set on the gateway service (images >= 1.0.22)?"
  exit 1
fi
if ! curl -sf http://localhost:5556/dex/.well-known/openid-configuration >/dev/null 2>&1; then
  bad "SSO (Dex) on :5556 not responding"; HEALTHY=0
else
  okk "SSO (Dex) on :5556 responding"
fi
[ "$HEALTHY" = 1 ] || { bad "unhealthy stack — run: $ENGINE compose up -d"; exit 1; }

# --- 1. sign in via SSO ------------------------------------------------------
step "Step 2 — sign in at the identity provider (SSO)"
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
  exit 1
fi

# --- 2. egress delegation: hosts, not tool paths -----------------------------
step "Step 3 — alice delegates EGRESS: example.com only, read + connect, ALL actions need approval"
DELEGATION=$(curl -s -X POST http://localhost:8081/v1/delegations/ \
  -H "Content-Type: application/json" \
  -d "{\"agent_id\":\"openclaw-agent-1\",\"resources\":[\"$HOST_ALLOW\"],\"actions\":[\"read\",\"connect\"],\
\"expires_in_seconds\":1800,\"id_token\":\"$ID_TOKEN\",\"approval_rules\":[{\
\"when\":{\"resource_pattern\":\"*\"},\"require\":true,\"rationale\":\"all outbound egress requires human approval\"}]}")
DELEGATION_ID=$(printf '%s' "$DELEGATION" | python3 -c "import sys,json; print(json.load(sys.stdin)['delegation']['id'])" 2>/dev/null || true)
AGENT_SECRET=$(printf '%s' "$DELEGATION" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agent_secret',''))" 2>/dev/null || true)
if [ -n "$DELEGATION_ID" ]; then
  okk "delegation created:  $DELEGATION_ID"
  line "scope: $HOST_ALLOW [read, connect] · approval rule: * → human decides EVERY call"
else
  bad "delegation refused:  $(printf '%s' "$DELEGATION" | head -c 200)"
  exit 1
fi

# --- 3. the agent mints its short-lived token --------------------------------
step "Step 4 — agent mints a short-lived token (the proxy credential)"
AGENT_TOKEN=$(curl -s -X POST http://localhost:8082/token \
  -H "Content-Type: application/json" \
  -d "{\"delegation_id\":\"$DELEGATION_ID\",\"ttl_seconds\":600,\"agent_secret\":\"$AGENT_SECRET\"}" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('access_token') or d.get('token',''))" 2>/dev/null || true)
if [ -n "$AGENT_TOKEN" ]; then
  okk "agent token issued (${#AGENT_TOKEN} chars, ttl 10 minutes)"
  line "it doubles as the Proxy-Authorization bearer — one credential, every request audited"
else
  bad "mint failed"; exit 1
fi

egress() { # method url extra-curl-args... -> status code
  echo "$@"
}

# helper: proxied request WITHOUT credentials
call_plain() { # url -> code
  curl -s -o /tmp/demo_egress.json -w "%{http_code}" --max-time 25 \
    --proxy "$PROXY_URL" "$1" || echo 000
}
call_with_token() { # url -> code   (plain HTTP through the proxy)
  curl -s -o /tmp/demo_egress.json -w "%{http_code}" --max-time 25 \
    --proxy "$PROXY_URL" -H "Proxy-Authorization: Bearer $AGENT_TOKEN" "$1" || echo 000
}
call_tls() { # url -> code (CONNECT tunnel, host allowlisted by the gateway)
  curl -s -o /tmp/demo_egress.json -w "%{http_code}" --max-time 25 \
    --proxy "$PROXY_URL" --proxy-header "Proxy-Authorization: Bearer $AGENT_TOKEN" "$1" || echo 000
}
approve() { # approval_id -> code
  curl -s -o /tmp/demo_appr.json -w "%{http_code}" -X POST $GW/v1/approvals/ \
    -H "Content-Type: application/json" -H "X-Admin-Token: $ADMIN_TOKEN" \
    -d "{\"approval_id\":\"$1\",\"approver_id\":\"$APPROVER\",\"approved\":true}"
}

# --- 4. no credential, no proxying ------------------------------------------
step "Step 5 — a credential-less call reaches the door and is refused"
C=$(call_plain "http://$HOST_ALLOW/")
if [ "$C" = "407" ]; then
  okk "HTTP 407 — proxy authentication required; nothing was proxied"
else
  bad "HTTP $C (expected 407): $(head -c 160 /tmp/demo_egress.json)"
fi

# --- 5. first delegated call: held for a human -------------------------------
step "Step 6 — example.com read: everything is a policy decision — hold"
C=$(call_with_token "http://$HOST_ALLOW/")
APPROVAL_ID=$(python3 -c "import sys,json; d=json.load(open('/tmp/demo_egress.json')); print(d.get('approval_id',''),d.get('status',''))" 2>/dev/null || true)
if [ "$C" = "202" ]; then
  okk "HTTP 202 — approval_required: the outbound call is HELD until a human permits it"
  echo "$APPROVAL_ID" | while read -r aid _; do line "approval_id:  $aid"; done
  line "the demoapi-style audit records alice/agent/host/action like any tool call"
else
  bad "HTTP $C (expected 202):  $(head -c 200 /tmp/demo_egress.json)"
fi

# --- 6. human approves → call goes through -----------------------------------
step "Step 7 — approve, and retry: the destination is reachable under authority"
PID=$(echo "$APPROVAL_ID" | grep -o 'apr-[a-f0-9]*' | head -1)
DEC=$(approve "$PID")
if [ "$DEC" = "200" ]; then
  okk "approval granted (approver bound to the SSO subject, single-use)"
else
  bad "approval failed (HTTP $DEC):  $(head -c 200 /tmp/demo_appr.json)"
fi
C=$(call_with_token "http://$HOST_ALLOW/")
if [ "$C" = "200" ]; then
  okk "HTTP 200 — executed under the human's decision, audited"
else
  bad "HTTP $C (expected 200):  $(head -c 200 /tmp/demo_egress.json)"
fi

# --- 7. undelegated host: policy denies --------------------------------------
step "Step 8 — undelegated host: the policy denies, no human needed"
C=$(call_with_token "http://$HOST_DENY/")
if [ "$C" = "403" ]; then
  okk "HTTP 403 policy_denied — the delegation names example.com only"
else
  bad "HTTP $C (expected 403):  $(head -c 160 /tmp/demo_egress.json)"
fi

# --- 8. TLS: CONNECT tunnel, held + approved, then the door opens ------------
step "Step 9 — HTTPS via CONNECT: host allowlisted, tunnel blind-forwarded"
# A plain curl can't judge this leg: when the proxy answers a CONNECT with
# 202 (held), curl treats it as a failed tunnel and hides the body. So this
# step speaks raw HTTP through /dev/tcp and reads the real proxy response.
raw_connect() { # authority token -> raw first status line (+ drained body on holds)
  # Uses a python3 socket instead of bash's /dev/tcp: macOS's stock bash
  # does not support /dev/tcp redirection, and python3 is already a
  # prerequisite of the demo stack (demo.sh uses it for the SSO flow).
  local authority="$1" tok="$2"
  python3 - "$authority" "$tok" "$PROXY_HOST" "$PROXY_PORT" <<'PY'
import socket, sys
authority, tok, phost, pport = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
try:
    s = socket.create_connection((phost, pport), 10)
except OSError:
    print("CONNECT-FAILED"); raise SystemExit
s.sendall((f"CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n"
           f"Proxy-Authorization: Bearer {tok}\r\nConnection: close\r\n\r\n").encode())
out = b""
while True:
    chunk = s.recv(4096)
    if not chunk: break
    out += chunk
    if out.startswith(b"HTTP/1.1 200"): break  # tunnel granted — stop reading
s.close()
out = out.decode(errors="replace")
lines = out.splitlines()
print(lines[0] if lines else "CONNECT-FAILED")
if not out.startswith("HTTP/1.1 200"):
    sys.stdout.write(out)   # holds/denials: server closed after one response
PY
}
RAW=$(raw_connect "$HOST_ALLOW:443" "$AGENT_TOKEN")
STATUS=$(echo "$RAW" | head -1)
APPROVAL_ID=$(echo "$RAW" | grep -o 'apr-[a-f0-9]*' | head -1)
case "$STATUS" in
  *202*)
    okk "HTTP 202 — the tunnel is held like every other call"
    line "approval_id:  $APPROVAL_ID"
    DEC=$(approve "$APPROVAL_ID")
    [ "$DEC" = "200" ] && okk "tunnel approved (approver bound to the SSO subject)" || bad "tunnel approval failed (HTTP $DEC)"
    ;;
  *200*)
    warn "CONNECT went straight through — that approval was already consumed this run"
    ;;
  *)
    bad "CONNECT refused (raw status: $STATUS)"
    ;;
esac
RAW2=$(raw_connect "$HOST_ALLOW:443" "$AGENT_TOKEN")
STATUS2=$(echo "$RAW2" | head -1)
case "$STATUS2" in
  *200*)
    okk "HTTP/1.1 200 Connection established — the tunnel is open; TLS is end to end"
    line "(the gateway saw host:port only; a future TLS-terminating mode can go deeper)"
    ;;
  *202*)
    warn "held again — approvals are single-use, which is the point; connect action needs one decision per call"
    APPROVAL_ID2=$(echo "$RAW2" | grep -o 'apr-[a-f0-9]*' | head -1)
    DEC=$(approve "$APPROVAL_ID2")
    [ "$DEC" = "200" ] && okk "approved" || bad "approval failed ($DEC)"
    RAW3=$(raw_connect "$HOST_ALLOW:443" "$AGENT_TOKEN"); STATUS3=$(echo "$RAW3" | head -1)
    case "$STATUS3" in *200*) okk "HTTP/1.1 200 Connection established — tunnel allowed now" ;; *) bad "tunnel still closed ($STATUS3)" ;; esac
    ;;
  *)
    bad "tunnel status unexpected: $STATUS2"
    ;;
esac

# --- 9. revocation closes every door instantly -------------------------------
step "Step 10 — revoke the delegation: even the tunnel door closes"
curl -s -X DELETE "http://localhost:8081/v1/delegations/$DELEGATION_ID" >/dev/null 2>&1 || true
C=$(call_with_token "http://$HOST_ALLOW/")
if [ "$C" = "403" ]; then
  okk "HTTP 403 — denied at enforcement though the token is still cryptographically valid"
else
  bad "HTTP $C (expected 403):  $(head -c 160 /tmp/demo_egress.json)"
fi

# --- summary -----------------------------------------------------------------
step "Demo summary"
line "OpenShell-style walls, Agent-Gateway doors:"
line "  · no credentials → 407 (the proxy is never an open relay)"
line "  · every destination = ONE decision: policy may deny outright or hold for a human"
line "  · approvals bind to (delegation, destination host, action) and are single-use"
line "  · undelegated hosts are denied by policy without bothering a human"
line "  · CONNECT tunnels are host:port-allowlisted; TLS stays end to end"
line "  · revocation beats valid tokens immediately"
echo ""
line "Audit:  $ENGINE compose logs gateway | grep egress   (alice / agent / host / why permitted)"
line "Explore: Web console http://localhost:8083  ·  docs/OpenShell-Integration.md (main repo)"
echo ""

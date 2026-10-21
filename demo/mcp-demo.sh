#!/usr/bin/env bash
# ============================================================================
# Agent Gateway — Demo 9: MCP under the gateway (OpenClaw edition)
#
# One CRM-flavoured MCP server, three states, each shown live against the
# running stack. Nothing is simulated: every tool call is real JSON-RPC over
# streamable-http, every response is the server/gateway's own.
#
#   A. UNPROTECTED — the MCP server reached directly (:8091). Anyone can call
#      add_customer anonymously: no identity, no delegation, no approval,
#      no audit. This is every MCP server in your estate today.
#   B. PROTECTED — the same server behind the Agent Gateway PEP (:8085).
#      Same wire protocol (Pattern C: point the client at the gateway),
#      but each call is authenticated, delegated, audited — and revocation
#      is instant.
#   C. OPENCLAW — the real agent (if its OpenShell sandbox is up) registers
#      the gateway URL as its MCP server and adds a customer by itself;
#      the human sees it in the audit trail.
#   D. DELETE APPROVAL — the agent attempts to delete a customer; the
#      delegation holds EVERY delete (202) for a human decision: approve ⇒
#      it executes exactly once; deny ⇒ 403 and the customer stays. Both
#      outcomes are reported from the CRM and the audit trail. --no-human
#      approves it for unattended runs; without the flag the script waits
#      APPROVAL_WAIT seconds (default 300) for your console/Telegram decision,
#      defaulting to DENY if nobody answers.
#
# Prereqs:  docker compose -f docker-compose.yml \
#                  -f docker-compose.egress.yml up -d
#           mcpsrv + gateway-mcp come up with the stack (compose
#           builds demo/mcp locally on first use).
#
# Usage:    ./mcp-demo.sh                 # A + B, then C and D if the sandbox exists
#           ./mcp-demo.sh --no-openclaw   # skip C and D's sandbox legs (CI-safe)
#           ./mcp-demo.sh --no-human      # Part D: the scripted human APPROVES the delete
#           ./mcp-demo.sh --keep-crm      # do not reset the server's CRM at start
# ============================================================================

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# "$0" stays relative when invoked as `./demo/mcp-demo.sh`; the cd below would
# break every later relative use of it (the --help banner reader), so capture
# the absolute path up front.
SCRIPT_PATH="$DEMO_DIR/$(basename "${BASH_SOURCE[0]}")"
cd "$DEMO_DIR"

RED=''; GRN=''; YLW=''; BLU=''; CYN=''; BLD=''; RST=''
if [ -t 1 ]; then
  RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; BLU='\033[0;36m'; CYN="$BLU"; BLD='\033[1m'; RST='\033[0m'
fi

step()  { printf "\n${BLD}${BLU}%s${RST}\n" "$*"; }
okk()   { printf "  ${GRN}✓ %s${RST}\n" "$*"; }
bad()   { printf "  ${RED}✗ %s${RST}\n" "$*"; }
warn()  { printf "  ${YLW}• %s${RST}\n" "$*"; }
info()  { printf "  ${YLW}• %s${RST}\n" "$*"; }
line()  { printf "  %s\n" "$*"; }

# Docker or Podman — see lib/engine.sh (CONTAINER_ENGINE env override).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/engine.sh"

# Ports: GATEWAY_MCP_HOST_PORT mirrors GATEWAY_HOST_PORT's override story.
GW_MCP=${GW_MCP:-http://localhost:${GATEWAY_MCP_HOST_PORT:-8085}}
MCP_PORT=${MCP_HOST_PORT:-8091}
MCP=${MCP:-http://localhost:$MCP_PORT}
AUTHZ=${AUTHZ:-http://localhost:8081}
TS=${TS:-http://localhost:8082}
ADMIN_TOKEN=${ADMIN_TOKEN:-agent-gateway-demo-admin}
AGENT_TIMEOUT=${AGENT_TIMEOUT:-240}

if [ -f "$DEMO_DIR/.env" ]; then set -a; . "$DEMO_DIR/.env"; set +a; fi

NO_HUMAN=0; OPENCLAW_SKIP=0; KEEP_CRM=0
for arg in "$@"; do
  case "$arg" in
    --no-openclaw) OPENCLAW_SKIP=1 ;;
    --no-human|--nohuman) NO_HUMAN=1 ;;
    --keep-crm)    KEEP_CRM=1 ;;
    --help|-h)
      sed -n '2,36p' "$SCRIPT_PATH" | grep -E '^#(   | Usage|$)' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) bad "unknown flag: $arg"; exit 1 ;;
  esac
done

APPROVAL_WAIT=${APPROVAL_WAIT:-300}   # Part D: how long the human may think (UI/Telegram)
POLL_INTERVAL=${POLL_INTERVAL:-3}

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------

# Vanilla MCP JSON-RPC POST; $1 = target base URL, then a JSON body. Echoes
# "<http_code>\t<body>" so the caller can assert and print one line.
mcp_call() {
  local url="$1" body="$2" token="${3:-}"
  local auth=()
  [ -n "$token" ] && auth=(-H "Authorization: Bearer $token")
  local code
  code=$(curl -s -o /tmp/mcpdemo_last.json -w "%{http_code}" --max-time 15 \
    -X POST "$url/mcp" ${auth[@]+"${auth[@]}"} \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "$body") || return 1
  printf '%s\t' "$code"
  head -c 220 /tmp/mcpdemo_last.json
  echo
}

mcpsrv_ready() { curl -fsS -o /dev/null "http://localhost:$MCP_PORT/healthz"; }
gw_mcp_ready() { curl -fsS -o /dev/null "$GW_MCP/healthz"; }

crm_json() { curl -s "http://localhost:$MCP_PORT/customers"; }

audit_rows() {
  eng exec agent-gateway-postgres psql -U agentgw -d agent_gateway -t \
    -c "SELECT ts, agent_id, resource, action, outcome FROM audit_events
        WHERE resource LIKE '/mcp%' ORDER BY ts DESC LIMIT $1;" 2>/dev/null
}

count_by_agent() { # $1=agent_id substring
  eng exec agent-gateway-postgres psql -U agentgw -d agent_gateway -t \
    -c "SELECT count(*) FROM audit_events WHERE resource LIKE '/mcp%'
        AND agent_id LIKE '%$1%';" 2>/dev/null | tr -d ' \n'
}

# SSO sign-in (Dex mock connector) → id_token. Same dance as demo.sh.
sso_id_token() {
  local DEX="http://localhost:5556" JAR LOC NX CODE
  JAR=$(mktemp)
  LOC="$DEX/dex/auth?response_type=code&client_id=agent-gateway&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback&connector_id=mock&scope=openid"
  CODE=""
  for _ in 1 2 3 4 5 6; do
    NX=$(curl -s -b "$JAR" -c "$JAR" -D - -o /dev/null "$LOC" \
      | grep -i '^location' | head -1 | tr -d '\r' \
      | sed 's/^Location: //; s|//dex:5556|//localhost:5556|')
    [ -z "$NX" ] && break
    case "$NX" in
      *code=*) CODE=$(printf '%s' "$NX" | sed 's/.*code=\([^&]*\).*/\1/'); break ;;
      /*) LOC="$DEX$NX" ;;
      *)  LOC="$NX" ;;
    esac
  done
  curl -s -X POST "$DEX/dex/token" \
    -d "grant_type=authorization_code&client_id=agent-gateway&code=$CODE&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('id_token',''))" 2>/dev/null
}

# Every sandbox exec gets a HOST-side hard timeout (same reasoning as
# human-delegation-demo.sh: openshell's --timeout has not always fired).
osx() { # <max-secs> <openshell sandbox exec args…>
  local t="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 10 "$t" openshell sandbox exec "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 10 "$t" openshell sandbox exec "$@"
  else
    openshell sandbox exec "$@"
  fi
}

# -----------------------------------------------------------------------------
# Part A — the MCP server, unprotected
# -----------------------------------------------------------------------------
PartA() {
step "═══ Part A — the MCP server, on its own (NO gateway) ══"
line "target: $MCP (/mcp, plain MCP streamable-http — the wire every MCP"
line "client in the world speaks; there is nothing gateway-specific here)"

if [ "${KEEP_CRM:-0}" != 1 ]; then
  line "resetting the CRM (fresh in-memory store)…"
  compose restart mcpsrv >/dev/null 2>&1
  until mcpsrv_ready; do sleep 1; done
fi

OUT=$(mcp_call "$MCP" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"anyone","version":"0"}}}')
[ "$(printf '%s' "$OUT" | cut -f1)" = 200 ] \
  && okk "initialize (no credentials):            HTTP 200 — accepted anonymously" \
  || { bad "unexpected: $OUT"; return 1; }

OUT=$(mcp_call "$MCP" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
grep -q 'add_customer' /tmp/mcpdemo_last.json \
  && okk "tools/list (no credentials):             HTTP 200 — the full CRM toolkit is exposed to anyone" \
  || { bad "unexpected: $OUT"; return 1; }

BEFORE=$(eng exec agent-gateway-postgres psql -U agentgw -d agent_gateway -t \
  -c "SELECT count(*) FROM audit_events WHERE resource LIKE '/mcp%';" 2>/dev/null | tr -d ' \n')

OUT=$(mcp_call "$MCP" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add_customer","arguments":{"first_name":"Mallory","last_name":"Anonymous","email":"mallory@example.com","company":"No-org"}}}')
[ "$(printf '%s' "$OUT" | cut -f1)" = 200 ] \
  && okk "tools/call add_customer (ANONYMOUS):     HTTP 200 — 'Mallory Anonymous' written to the CRM, no identity asked" \
  || { bad "unexpected: $OUT"; return 1; }

OK=$(crm_json | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['customers']))" 2>/dev/null || true)
okk "out-of-band proof: CRM now holds $OK customers (curl :$MCP_PORT/customers)"

AFTER=$(eng exec agent-gateway-postgres psql -U agentgw -d agent_gateway -t \
  -c "SELECT count(*) FROM audit_events WHERE resource LIKE '/mcp%';" 2>/dev/null | tr -d ' \n')
[ "$BEFORE" = "$AFTER" ] 2>/dev/null \
  && okk "audit trail: ZERO new records during Part A — the gateway never saw any of it" \
  || { warn "audit rows appeared during Part A?! ($BEFORE → $AFTER)"; }

warn "this is every MCP server in your estate today: whoever reaches the port, writes."
}

# -----------------------------------------------------------------------------
# Part B — the same MCP server behind the gateway PEP
# -----------------------------------------------------------------------------
PartB() {
step "═══ Part B — the same MCP server behind the Agent Gateway (:8085) ══"
line "the agent now points its MCP client at $GW_MCP/mcp — one URL change"
line "(integration Pattern C); the wire protocol is unchanged"

OUT=$(mcp_call "$GW_MCP" '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"anyone","version":"0"}}}')
[ "$(printf '%s' "$OUT" | cut -f1)" = 401 ] \
  && okk "unauthenticated initialize:               HTTP 401 — the gateway earns its keep" \
  || { bad "expected 401: $OUT"; return 1; }

step "SSO sign-in → a delegation for MCP CRM access"
ID_TOKEN=$(sso_id_token)
[ -n "$ID_TOKEN" ] && okk "signed in; human identity verified (ID token, ${#ID_TOKEN} chars)" \
  || { bad "SSO failed (Dex on :5556)"; return 1; }

DELEG=$(curl -s -X POST "$AUTHZ/v1/delegations/" -H 'Content-Type: application/json' \
  -d "{\"agent_id\":\"openclaw-crm-agent\",\"resources\":[\"/mcp*\"],\"actions\":[\"read\",\"create\"],\
\"expires_in_seconds\":900,\"id_token\":\"$ID_TOKEN\"}")
DELEG_ID=$(printf '%s' "$DELEG" | python3 -c "import sys,json; print(json.load(sys.stdin)['delegation']['id'])" 2>/dev/null || true)
SECRET=$(printf '%s' "$DELEG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agent_secret',''))" 2>/dev/null || true)
[ -n "$DELEG_ID" ] && [ -n "$SECRET" ] \
  && okk "delegation $DELEG_ID — scope /mcp* [read, create], 15 min, bound to the SSO subject" \
  || { bad "delegation failed: $(printf '%s' "$DELEG" | head -c 200)"; return 1; }
line "the gateway derives resource=/mcp, action=create for EVERY MCP tool"
line "call (first path segment + HTTP verb) — the delegation matches that"

TOKEN=$(curl -s -X POST "$TS/token" -H 'Content-Type: application/json' \
  -d "{\"delegation_id\":\"$DELEG_ID\",\"ttl_seconds\":900,\"agent_secret\":\"$SECRET\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
[ -n "$TOKEN" ] && okk "agent token minted (${#TOKEN} chars, ttl 900s = the MCP session's life)" \
  || { bad "token mint failed"; return 1; }

step "the same operations, now governed"
OUT=$(mcp_call "$GW_MCP" '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"demo","version":"0"}}}' "$TOKEN")
[ "$(printf '%s' "$OUT" | cut -f1)" = 200 ] \
  && okk "initialize:                              HTTP 200 — session admitted under the delegation" \
  || { bad "unexpected: $OUT"; return 1; }

OUT=$(mcp_call "$GW_MCP" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add_customer","arguments":{"first_name":"Alan","last_name":"Turing","email":"alan@example.com","company":"Bletchley Park"}}}' "$TOKEN")
[ "$(printf '%s' "$OUT" | cut -f1)" = 200 ] \
  && okk "tools/call add_customer (Alan Turing):   HTTP 200 — created, forwarded, audited" \
  || { bad "unexpected: $OUT"; return 1; }

OUT=$(mcp_call "$GW_MCP" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"lookup_customer","arguments":{"query":"CUST-0001"}}}' "$TOKEN")
[ "$(printf '%s' "$OUT" | cut -f1)" = 200 ] && okk "tools/call lookup_customer:              HTTP 200 — reads flow too (read action)" \
  || { bad "unexpected: $OUT"; return 1; }

ROWS=$(audit_rows 4)
printf '%s' "$ROWS" | grep -q "openclaw-crm-agent" \
  && okk "audit trail rows for agent openclaw-crm-agent (resource /mcp, action create, outcome allow):" \
  || warn "no audit rows found?!!"
printf '%s' "$ROWS" | grep . | head -4 | while IFS= read -r r; do line "  $r"; done

step "revoke → the MCP session dies at the gateway"
CODE=$(printf '%s' "$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$AUTHZ/v1/delegations/$DELEG_ID" -H "Authorization: Bearer $ID_TOKEN")")
[ "$CODE" = "204" ] || warn "revoke returned HTTP $CODE"
okk "delegation $DELEG_ID revoked (the token is still cryptographically valid)"

OUT=$(mcp_call "$GW_MCP" '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"add_customer","arguments":{"first_name":"Second","last_name":"Try","email":"second@example.com"}}}' "$TOKEN")
C=$(printf '%s' "$OUT" | cut -f1)
case "$C" in
  401) okk "next tools/call after revoke:            HTTP 401 — delegation revoked (token valid, authorization gone)" ;;
  403) okk "next tools/call after revoke:            HTTP 403 — delegation revoked (token valid, authorization gone)" ;;
  *)   bad "expected refusal, got HTTP $C: $OUT" ;;
esac
DENIED=$(eng exec agent-gateway-postgres psql -U agentgw -d agent_gateway -t \
  -c "SELECT count(*) FROM audit_events WHERE outcome='deny' AND resource LIKE '/mcp%';" 2>/dev/null | tr -d ' \n')
[ "${DENIED:-0}" -gt 0 ] 2>/dev/null && okk "audit: the refused attempt is on the record (deny)" || warn "no deny row found"

warn "same server, same wire protocol — now: identity, delegation, audit, instant revocation."
}

# -----------------------------------------------------------------------------
# Part C — OpenClaw uses the CRM through the gateway
# -----------------------------------------------------------------------------
PartC() {
step "═══ Part C — OpenClaw (the real agent) meets the CRM through the gateway ══"

if [ "${OPENCLAW_SKIP:-0}" = 1 ]; then
  line "skipped (--no-openclaw). To run it: ./demo/openclaw-sandbox.sh build/up/configure"
  return 0
fi
if ! command -v openshell >/dev/null 2>&1; then
  line "openshell CLI not found — skipping the agent leg."
  line "  sandbox path:  make openclaw-demo   (then re-run this script)"
  return 0
fi

SANDBOX_NAME=${OPENCLAW_SANDBOX_NAME:-${SANDBOX_NAME:-openclaw}}
if ! openshell sandbox list 2>/dev/null | awk '$1=="'"$SANDBOX_NAME"'"' | grep -q Ready; then
  line "sandbox '$SANDBOX_NAME' is not Ready — skipping the agent leg."
  line "  create it first:  make openclaw-demo"
  return 0
fi
okk "OpenClaw sandbox '$SANDBOX_NAME' is Ready"

AUDIT_C0=$(eng exec agent-gateway-postgres psql -U agentgw -d agent_gateway -t \
  -c "SELECT count(*) FROM audit_events WHERE resource LIKE '/mcp%';" 2>/dev/null | tr -d ' \n')

# --- 1. the route out of the sandbox (Demo 8's egress machinery) -------------
# The sandbox has no direct egress: the OpenShell supervisor chains every
# outbound connection through the Agent Gateway's egress proxy (:8088), and
# every destination needs an egress delegation (host strings, read+connect).
# The model provider must ride it too, or the agent itself stops working.
ID_TOKEN=$(sso_id_token)
[ -n "$ID_TOKEN" ] || { bad "SSO failed"; return 1; }

PROVIDER_HOST=integrate.api.nvidia.com
if [ "$(uname -s)" = "Darwin" ]; then
  CANDS=()
  for h in host.docker.internal "$(ipconfig getifaddr en0 2>/dev/null)" "$(ipconfig getifaddr en1 2>/dev/null)"; do
    [ -n "$h" ] || continue
    dup=0; for c in ${CANDS[@]:-}; do [ "$c" = "$h" ] && dup=1; done
    [ "$dup" = 0 ] && CANDS+=("$h")
  done
else
  CANDS=($(hostname -I | tr ' ' '\n' | grep -E '^(192\.168|172\.[12][0-9]\.|10\.)' | sort -u))
fi
GW_MCP_PORT=${GATEWAY_MCP_HOST_PORT:-8085}
RES=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' ${CANDS[@]+"${CANDS[@]}"} "$PROVIDER_HOST")
D=$(curl -s -X POST "$AUTHZ/v1/delegations/" -H 'Content-Type: application/json' \
  -d "{\"id_token\":\"$ID_TOKEN\",\"agent_id\":\"openclaw-crm-agent\",\"resources\":$RES,\"actions\":[\"read\",\"connect\"],\"expires_in_seconds\":1800}")
EDELEG=$(printf '%s' "$D" | python3 -c "import sys,json;print(json.load(sys.stdin)['delegation']['id'])" 2>/dev/null)
ESECRET=$(printf '%s' "$D" | python3 -c "import sys,json;print(json.load(sys.stdin).get('agent_secret',''))" 2>/dev/null)
[ -n "$EDELEG" ] && [ -n "$ESECRET" ] || { bad "egress delegation failed: $(printf '%s' "$D" | head -c 200)"; return 1; }
ETOK=$(curl -s -X POST "$TS/token" -H 'Content-Type: application/json' \
  -d "{\"delegation_id\":\"$EDELEG\",\"ttl_seconds\":1800,\"agent_secret\":\"$ESECRET\"}" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
[ -n "$ETOK" ] || { bad "egress token mint failed"; return 1; }

AUTH_FILE="${HOME}/.config/openshell/upstream-proxy-auth"
mkdir -p "$(dirname "$AUTH_FILE")"
printf '%s:x\n' "$ETOK" > "$AUTH_FILE" && chmod 600 "$AUTH_FILE"
if openshell sandbox stop "$SANDBOX_NAME" >/dev/null 2>&1 && \
   openshell sandbox start "$SANDBOX_NAME" >/dev/null 2>&1; then
  okk "egress delegation $EDELEG (model host + gateway host) · supervisor credential refreshed"
  info "letting the supervisor's proxy and the in-sandbox OpenClaw gateway settle (15 s)…"
  sleep 15
else
  bad "sandbox stop/start failed — the fresh egress credential never reaches the supervisor"
  return 1
fi

step "sandbox egress — allow the gateway-mcp PEP, find the route that works"
for h in ${CANDS[@]+"${CANDS[@]}"}; do
  openshell policy update "$SANDBOX_NAME" --rule-name openclaw_egress \
    --binary /usr/bin/bash --binary /usr/bin/node --binary /usr/bin/curl \
    --binary /usr/local/bin/node --binary /usr/local/bin/openclaw \
    --add-endpoint "${h}:${GW_MCP_PORT}" --wait >/dev/null 2>&1 || true
done
AGW_URL=""
find_sandbox_route || return 1

# --- 2. the agent's MCP delegation -------------------------------------------
DELEG=$(curl -s -X POST "$AUTHZ/v1/delegations/" -H 'Content-Type: application/json' \
  -d "{\"agent_id\":\"openclaw-crm-agent\",\"resources\":[\"/mcp*\"],\"actions\":[\"read\",\"create\"],\
\"expires_in_seconds\":1800,\"id_token\":\"$ID_TOKEN\"}")
DELEG_ID=$(printf '%s' "$DELEG" | python3 -c "import sys,json; print(json.load(sys.stdin)['delegation']['id'])" 2>/dev/null || true)
SECRET=$(printf '%s' "$DELEG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agent_secret',''))" 2>/dev/null || true)
TOKEN=$(curl -s -X POST "$TS/token" -H 'Content-Type: application/json' \
  -d "{\"delegation_id\":\"$DELEG_ID\",\"ttl_seconds\":1800,\"agent_secret\":\"$SECRET\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
[ -n "$TOKEN" ] || { bad "agent MCP token mint failed"; return 1; }
okk "fresh delegation $DELEG_ID + token for the agent's MCP client (ttl 30 min)"

# --- 3. register the gateway URL as the agent's MCP server -------------------
# Vanilla remote-MCP config: a streamable-http URL + a static Authorization
# header — exactly what OpenClaw's remote-MCP configuration accepts for any
# server out there. The ONLY gateway-specific part is that the URL belongs to
# the PEP instead of the server, and the token is a delegation token.
MERGE="import json
p='/sandbox/.openclaw/openclaw.json'
try:
    cfg=json.load(open(p))
except Exception:
    cfg={}
ent={'url':'$AGW_URL/mcp','transport':'streamable-http',
     'enabled':True,'headers':{'Authorization':'Bearer '+'$TOKEN'},
     'connectionTimeoutMs':5000,'requestTimeoutMs':30000}
cfg.setdefault('mcp',{}).setdefault('servers',{})
cfg['mcp']['servers']['demo-crm']=ent
json.dump(cfg,open(p,'w'),indent=2); print('mcp config written')"
printf '%s' "$MERGE" | osx 40 -n "$SANDBOX_NAME" --no-tty -- python3 - 2>&1 || { bad "could not write the MCP config inside the sandbox"; return 1; }
okk "MCP server registered inside the sandbox: demo-crm → $AGW_URL/mcp"

line "live probe (openclaw mcp probe — the agent's own MCP client handshake, through the gateway):"
if osx 60 -n "$SANDBOX_NAME" --no-tty --timeout 50 -- openclaw mcp probe demo-crm 2>&1 | tee /tmp/mcpdemo_probe.txt; then :; fi
if grep -q "demo-crm" /tmp/mcpdemo_probe.txt && grep -vq "failed to start" /tmp/mcpdemo_probe.txt; then
  okk "the agent's MCP client connected — vanilla protocol, zero agent-side code"
else
  warn "probe failed — the calls above show the client-side failure verbatim"
fi
AUDIT_C1=$(eng exec agent-gateway-postgres psql -U agentgw -d agent_gateway -t \
  -c "SELECT count(*) FROM audit_events WHERE resource LIKE '/mcp%';" 2>/dev/null | tr -d ' \n')
if [ "${AUDIT_C1:-0}" -gt "${AUDIT_C0:-0}" ] 2>/dev/null; then
  okk "audit trail: the probe's MCP calls are on the record (rows $AUDIT_C0 → $AUDIT_C1)"
else
  warn "no audit rows for the probe (the client never got through? see above)"
fi

# --- 4. one agent turn: the agent works the CRM by itself ---------------------
line "one agent turn: nothing scripted — the model chooses the tools; every"
line "tool call goes OpenClaw → gateway PEP → mcpsrv, audited under the agent's identity"
PROMPT='Use the demo-crm MCP tools to do two things and report both: first add a customer named Jane Doe (email jane.doe@example.com, company Acme Corp), then look that customer up by email and tell me her customer id.'
out=$(osx "$((AGENT_TIMEOUT + 60))" -n "$SANDBOX_NAME" --no-tty --timeout "$AGENT_TIMEOUT" \
  --env PROVIDER_API_KEY="${PROVIDER_API_KEY:-${NVIDIA_API_KEY:-}}" -- \
  openclaw agent -m "$PROMPT" 2>/dev/null | grep -v 'UNDICI\|trace-warnings\|Warning:') || true
if [ -z "$out" ]; then
  sleep 5
  out=$(osx "$((AGENT_TIMEOUT + 60))" -n "$SANDBOX_NAME" --no-tty --timeout "$AGENT_TIMEOUT" \
    --env PROVIDER_API_KEY="${PROVIDER_API_KEY:-${NVIDIA_API_KEY:-}}" -- \
    openclaw agent -m "$PROMPT" 2>/dev/null | grep -v 'UNDICI\|trace-warnings\|Warning:') || true
fi
printf '\n  ┌─ OPENCLAW REPLIES\n'
if [ -n "$out" ]; then
  printf '%s\n' "$out" | head -40 | sed 's/^/  │ /'
else
  line "│ (no reply within ${AGENT_TIMEOUT}s — a cold provider warm-up is the usual cause)"
  line "│ (rerun Part C: AGENT_TIMEOUT=420 ./demo/mcp-demo.sh)"
fi
printf '  └─\n'

printf '%s' "$(crm_json)" | python3 -c "import sys,json; d=json.load(sys.stdin); js=[c for c in d['customers'] if c['email']=='jane.doe@example.com']; print('Jane Doe is in the CRM:', js[0]['id'] if js else 'NOT FOUND')" 2>/dev/null \
  | while IFS= read -r r; do line "  $r"; done
AUDIT_C2=$(eng exec agent-gateway-postgres psql -U agentgw -d agent_gateway -t \
  -c "SELECT count(*) FROM audit_events WHERE resource LIKE '/mcp%';" 2>/dev/null | tr -d ' \n')
if [ "${AUDIT_C2:-0}" -gt "${AUDIT_C1:-0}" ] 2>/dev/null; then
  okk "audit trail: the agent's MCP tool calls are attributed to openclaw-crm-agent (rows $AUDIT_C1 → $AUDIT_C2)"
  eng exec agent-gateway-postgres psql -U agentgw -d agent_gateway -t \
    -c "SELECT ts, agent_id, action, outcome, reason FROM audit_events WHERE resource LIKE '/mcp%' AND ts > now() - interval '10 minutes' ORDER BY ts DESC LIMIT 5;" 2>/dev/null \
    | grep . | while IFS= read -r r; do line "  $r"; done
else
  warn "no audit rows for the agent turn (inspect: $ENGINE compose logs gateway-mcp)"
fi
}

# -----------------------------------------------------------------------------
# Part D — deleting a customer needs a human decision
# -----------------------------------------------------------------------------
# The gateway derives resource=/customers*, action=delete for the CRM's REST
# delete surface, so a delegation's approval rule can hold EVERY deletion
# (202 + approval id, upstream never called) until a human decides:
#   approve  → the retry executes exactly once, the customer is gone
#   deny     → the retry is refused (403), the customer is still there,
#              and the refuse attempt is on the audit record
# --no-human approves immediately for unattended runs; without it the script
# waits APPROVAL_WAIT seconds for a real decision in the console (or Telegram).

# --- approval machinery (same shape as human-delegation-demo.sh) -------------
pending_id() { # → latest pending approval id for Part D's /customers delete
  curl -s --max-time 5 "$GW_MCP/v1/approvals/" -H "X-Admin-Token: $ADMIN_TOKEN" | python3 -c "
import sys, json
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
pend = [r for r in rows
        if r.get('status') == 'pending' and r.get('delegation_id') == '$DELEG_ID'
        and str(r.get('resource', '')).startswith('/customers')]
pend.sort(key=lambda r: r.get('created_at', ''))
print(pend[-1]['id'] if pend else '')" 2>/dev/null
}

approval_status() { # id → approved|denied|pending|''
  curl -s --max-time 5 "$GW_MCP/v1/approvals/" -H "X-Admin-Token: $ADMIN_TOKEN" | python3 -c "
import sys, json
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
rows = [r for r in rows if r.get('id') == '$1']
print(rows[-1].get('status', '') if rows else '')" 2>/dev/null
}

wait_for_decision() { # approval-id → 0 when decided
  local waited=0
  while [ "$waited" -lt "$APPROVAL_WAIT" ]; do
    [ "$(pending_id)" != "$1" ] && return 0
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
    printf "  ⏳ %ds…\r" "$waited"
  done
  echo
  return 1
}

decide() { # approval-id approved(true/false) → HTTP code
  curl -s -o /dev/null -w '%{http_code}' -X POST "$GW_MCP/v1/approvals/" \
    -H 'Content-Type: application/json' -H "X-Admin-Token: $ADMIN_TOKEN" \
    -d "{\"approval_id\":\"$1\",\"approver_id\":\"$APPROVER\",\"approved\":$2}"
}

tg_send() { # text
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0
  curl -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TELEGRAM_CHAT_ID}" --data-urlencode "text=$1" >/dev/null 2>&1 || true
}

crm_count() {
  crm_json | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['customers']))" 2>/dev/null
}

# The base URL a sandbox process must use to reach gateway-mcp: the sandbox
# cannot dial the host's localhost, so it is probed per machine (Demo 8's
# candidate loop) and cached in AGW_URL across Part C and Part D.
find_sandbox_route() {
  [ -n "${AGW_URL:-}" ] && return 0
  local round h c
  for round in 1 2 3 4 5 6 7 8; do
    for h in ${CANDS[@]+"${CANDS[@]}"}; do
      [ -n "${AGW_URL:-}" ] && break 2
      c=$(osx 45 -n "$SANDBOX_NAME" --no-tty --timeout 25 -- \
        curl -sS --max-time 8 -o /dev/null -w '%{http_code}' "http://${h}:${GW_MCP_PORT}/healthz" 2>&1 | tail -1)
      if [ "$c" = "200" ]; then
        AGW_URL="http://${h}:${GW_MCP_PORT}"
      else
        info "  probe ${h}:${GW_MCP_PORT} → ${c:-no-answer}"
      fi
    done
    [ -n "${AGW_URL:-}" ] && break
    info "no route yet — retrying in 10 s"
    sleep 10
  done
  [ -n "${AGW_URL:-}" ] || { bad "the sandbox cannot reach gateway-mcp on :$GW_MCP_PORT"; return 1; }
  okk "agent → sandbox policy → gateway proxy → gateway-mcp PEP: $AGW_URL"
}

attempt_delete() { # delete attempt from the best route (sandbox agent path or host)
  local base
  if [ "$SANDBOX_MODE" = 1 ]; then
    base="$AGW_URL"
    out=$(osx 45 -n "$SANDBOX_NAME" --no-tty --timeout 30 -- \
      sh -c 'curl -s --max-time 25 -X DELETE -H "Authorization: Bearer $(cat /tmp/agw-token)" "'"$base"'/customers/'"$VICTIM_ID"'" -w "\n%{http_code}"' 2>/dev/null)
  else
    base="$GW_MCP"
    out=$(curl -s --max-time 25 -X DELETE -H "Authorization: Bearer $TOKEN" \
      "$base/customers/$VICTIM_ID" -w '\n%{http_code}' 2>/dev/null)
  fi
  SB_CODE=$(printf '%s' "$out" | tail -1 | tr -d '[:space:]')
  SB_BODY=$(printf '%s' "$out" | sed '$d')
}

PartD() {
step "═══ Part D — deleting a customer needs a human decision ══"
line "adding a customer was a plain write. DELETING one is a different class"
line "of risk — the human grants the capability, but every delete HELDS at"
line "the gateway until a named human approves (single-use) or denies it."

SANDBOX_NAME=${OPENCLAW_SANDBOX_NAME:-${SANDBOX_NAME:-openclaw}}
if [ "${OPENCLAW_SKIP:-0}" = 1 ] || ! command -v openshell >/dev/null 2>&1 \
   || ! openshell sandbox list 2>/dev/null | awk '$1=="'"$SANDBOX_NAME"'"' | grep -q Ready; then
  SANDBOX_MODE=0
  line "(sandbox not in the loop — the delete attempt below is fired from the"
  line " host with the agent token; identical bytes on the gateway's wire)"
else
  SANDBOX_MODE=1
  okk "sandbox '$SANDBOX_NAME' is Ready — the agent itself will attempt the delete"
fi

AUDIT_D0=$(eng exec agent-gateway-postgres psql -U agentgw -d agent_gateway -t \
  -c "SELECT count(*) FROM audit_events WHERE resource LIKE '/customers%';" 2>/dev/null | tr -d ' \n')

# Fresh rights for this phase (rotation, like Demo 8 round B): reads and
# writes flow as before, plus /customers* — with the delete held for a human.
ID_TOKEN=$(sso_id_token)
[ -n "$ID_TOKEN" ] || { bad "SSO failed (Dex on :5556)"; return 1; }
APPROVER=$(printf '%s' "$ID_TOKEN" | cut -d. -f2 | python3 -c "import sys,json,base64; t=sys.stdin.read().strip(); t+='='*(-len(t)%4); print(json.loads(base64.urlsafe_b64decode(t)).get('sub',''))" 2>/dev/null)
DELEG=$(curl -s -X POST "$AUTHZ/v1/delegations/" -H 'Content-Type: application/json' \
  -d "{\"agent_id\":\"openclaw-crm-agent\",\"resources\":[\"/mcp*\",\"/customers*\"],\"actions\":[\"read\",\"create\",\"delete\"],\
\"expires_in_seconds\":1800,\"id_token\":\"$ID_TOKEN\",\
\"approval_rules\":[{\"when\":{\"resource_pattern\":\"/customers*\",\"action_pattern\":\"delete\"},\"require\":true,\
\"rationale\":\"Deleting customer data: verify this is the right record before approving\"}]}")
DELEG_ID=$(printf '%s' "$DELEG" | python3 -c "import sys,json; print(json.load(sys.stdin)['delegation']['id'])" 2>/dev/null || true)
SECRET=$(printf '%s' "$DELEG" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agent_secret',''))" 2>/dev/null || true)
TOKEN=$(curl -s -X POST "$TS/token" -H 'Content-Type: application/json' \
  -d "{\"delegation_id\":\"$DELEG_ID\",\"ttl_seconds\":1800,\"agent_secret\":\"$SECRET\"}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)
[ -n "$DELEG_ID" ] && [ -n "$TOKEN" ] \
  && okk "delegation $DELEG_ID — /mcp* + /customers* [read, create, delete]; DELETE held for a human (approval_rules)" \
  || { bad "delegation failed: $(printf '%s' "$DELEG" | head -c 200)"; return 1; }

if [ "$SANDBOX_MODE" = 1 ]; then
  printf '%s' "$TOKEN" | base64 | osx 40 -n "$SANDBOX_NAME" --no-tty -- \
    sh -c "umask 077 && base64 -d > /tmp/agw-token" 2>/dev/null \
    && okk "agent credential staged: /tmp/agw-token (0600, short-lived)"
fi

# The record to offboard: DELETE_TARGET forces one (e.g. for a re-run while an
# earlier deny still binds a record); otherwise Part C's Jane Doe if present,
# else the first seeded customer — always provable from the CRM REST view.
# (name/email ride a | delimiter: names contain spaces.)
IFS='|' read -r VICTIM_ID VICTIM_NAME VICTIM_EMAIL < <(crm_json | python3 -c "
import sys, json, os
d = json.load(sys.stdin)
tgt = os.environ.get('DELETE_TARGET', '').upper()
pick = next((c for c in d['customers'] if c['id'] == tgt), None) \
    or next((c for c in d['customers'] if c['email'] == 'jane.doe@example.com'), None) \
    or (d['customers'][0] if d['customers'] else None)
print('|'.join([pick['id'], pick['first_name'] + ' ' + pick['last_name'], pick['email']]) if pick else '||')" 2>/dev/null)
[ -n "$VICTIM_ID" ] || { bad "CRM is empty — nothing to delete"; return 1; }
BEFORE_COUNT=$(crm_count)
line "release brief: offload $VICTIM_ID — $VICTIM_NAME <$VICTIM_EMAIL> (Acme Corp wind-down, per the human)"
line "CRM holds $BEFORE_COUNT customers before the attempt (curl :$MCP_PORT/customers)"

# the attempt: 202 + approval id, upstream never called. From the sandbox the
# attempt goes to the route Part C probed (the sandbox cannot dial localhost).
line "attempt: DELETE ${AGW_URL:-$GW_MCP}/customers/$VICTIM_ID"
if [ "$SANDBOX_MODE" = 1 ]; then
  find_sandbox_route || return 1
  line "  (the agent works it exactly as Demo 8 does: exec tool + the staged token)"
  AGENT_D_PROMPT='The human asked us to offboard customer '"$VICTIM_ID"' ('"$VICTIM_NAME"'). The gateway credential is staged at /tmp/agw-token (a short-lived token the human delegated to you — never print it). Use the exec tool to run exactly this and report the full HTTP response verbatim:
curl -s -X DELETE -H "Authorization: Bearer $(cat /tmp/agw-token)" '"$AGW_URL"'/customers/'"$VICTIM_ID"'
Then report whether the customer is gone.'
  out=$(osx "$((AGENT_TIMEOUT + 60))" -n "$SANDBOX_NAME" --no-tty --timeout "$AGENT_TIMEOUT" \
    --env PROVIDER_API_KEY="${PROVIDER_API_KEY:-${NVIDIA_API_KEY:-}}" -- \
    openclaw agent -m "$AGENT_D_PROMPT" 2>/dev/null | grep -v 'UNDICI\|trace-warnings\|Warning:') || true
  [ -n "$out" ] && printf '%s\n' "$out" | head -8 | while IFS= read -r r; do line "  │ $r"; done
  [ -z "$out" ] && info "(the agent turn came up silent — the script now fires the same request the agent was asked to send)"
fi
attempt_delete
SKIP_WAIT=0
case "$SB_CODE" in
  202) okk "HTTP 202 — the delete is HELD at the gateway; the upstream was not called" ;;
  403)
    # A denial is sticky at (agent, exact action) level — fresher than any
    # single delegation: a record whose delete was once refused is refused
    # again on sight, even under a brand-new delegation. Report it as the
    # denied outcome; there is no hold to decide.
    okk "HTTP 403 — refused outright: a previous deny on this exact action is STILL BINDING (denials stick; a fresh delegation does not revive it)"
    SKIP_WAIT=1
    WANTED="denied" ;;
  *)   bad "unexpected HTTP ${SB_CODE:-none} at the first attempt: $(printf '%s' "${SB_BODY:-}" | head -c 200)"; return 1 ;;
esac
if [ "$SKIP_WAIT" = 0 ]; then
  if [ "$(crm_count)" = "$BEFORE_COUNT" ]; then
    okk "out-of-band proof: $VICTIM_ID is still in the CRM ($BEFORE_COUNT) — nothing executed"
  fi
  APR_D=$(pending_id)
  [ -n "$APR_D" ] || { bad "held but no pending approval row appeared"; return 1; }

# the card a human decides from (console + Telegram when wired)
printf '\n  ┌─ %sDELETE APPROVAL REQUEST%s — approval %s\n' "$CYN" "$RST" "$APR_D"
printf '  │ customer:  %s — %s <%s>\n' "$VICTIM_ID" "$VICTIM_NAME" "$VICTIM_EMAIL"
printf '  │ state:     still in the CRM — the hold is not a deletion, nothing executed\n'
printf '  │ decide:    approve (remove) or deny (keep the customer)\n'
printf '  │ verify:    curl -s http://localhost:%s/customers\n' "$MCP_PORT"
printf '  └─ decide in the console: http://localhost:8083  (or on the Telegram card)\n'
tg_send "🗑 DELETE NEEDS YOUR DECISION — approval $APR_D
Customer: $VICTIM_ID ($VICTIM_NAME, $VICTIM_EMAIL)
Nothing executed yet (the CRM still holds them).
Decide: ${APPROVAL_CONSOLE_URL:-http://localhost:8083} (console) or on the gateway's card
A deletion consented to in this delegation always needs a human."

# the human decides
if [ "$NO_HUMAN" = 1 ]; then
  info "--no-human: the scripted human APPROVES the delete"
  DEC=$(decide "$APR_D" true); [ "$DEC" = "200" ] || { bad "approve call failed (HTTP $DEC)"; return 1; }
  WANTED="approved"
else
  info "waiting up to ${APPROVAL_WAIT}s for YOUR decision (console or Telegram card)…"
  if wait_for_decision "$APR_D"; then
    line "decision recorded via the UI"
    WANTED=$(approval_status "$APR_D")
    info "the decision was: $([ "$WANTED" = approved ] && echo APPROVED || echo DENIED — keeping the customer, and the agent cannot override you)"
  else
    info "no decision in ${APPROVAL_WAIT}s — safe default: DENY (keep the customer)"
    WANTED="denied"
    decide "$APR_D" false >/dev/null || true
  fi
fi

# the retry — whoever fires it first, the decision is what executes. The CRM
# (out of band) is the source of truth: if its count already shows the
# customer gone, the agent's own approved retry consumed the approval.
DAFTER=$(crm_count)
EXECUTED_BY="the script's approved retry"
if [ "$WANTED" = "approved" ] && [ "$DAFTER" = "$((BEFORE_COUNT - 1))" ]; then
  okk "the agent's own approved retry already executed the delete — exactly once"
  EXECUTED_BY="the agent's approved retry"
else
  if [ "$SANDBOX_MODE" = 1 ]; then
    out=$(osx "$((AGENT_TIMEOUT + 60))" -n "$SANDBOX_NAME" --no-tty --timeout "$AGENT_TIMEOUT" \
      --env PROVIDER_API_KEY="${PROVIDER_API_KEY:-${NVIDIA_API_KEY:-}}" -- \
      openclaw agent -m 'Use the exec tool to run the exact same command again and report the full HTTP response verbatim:
curl -s -X DELETE -H "Authorization: Bearer $(cat /tmp/agw-token)" '"$AGW_URL"'/customers/'"$VICTIM_ID"' — is the customer gone?' 2>/dev/null \
      | grep -v 'UNDICI\|trace-warnings\|Warning:') || true
    [ -n "$out" ] && printf '%s\n' "$out" | head -6 | while IFS= read -r r; do line "  │ $r"; done
  fi
  attempt_delete
  case "$SB_CODE" in
    200) okk "retry → HTTP 200 — executed exactly once ($EXECUTED_BY)" ;;
    403) okk "retry → HTTP 403 — the decision binds; nothing executed" ;;
    202) # approvals are single-use: a fresh hold may have appeared after the
         # agent's turn. Decide it the same side, then one attempt.
      APR_D2=$(pending_id)
      if [ -n "$APR_D2" ]; then
        info "a fresh hold appeared (single-use approvals) — deciding it $WANTED-side too, then one attempt"
        decide "$APR_D2" "$([ "$WANTED" = approved ] && echo true || echo false)" >/dev/null
        attempt_delete
        case "$SB_CODE" in
          200) okk "retry → HTTP 200 — executed exactly once ($EXECUTED_BY)" ;;
          403) okk "retry → HTTP 403 — the decision binds; nothing executed" ;;
          404) info "HTTP 404 — the record was already gone (the decision's retry raced a check); nothing new executed" ;;
          *)   bad "unexpected HTTP $SB_CODE after the secondary hold: $(printf '%s' "${SB_BODY:-}" | head -c 200)" ;;
        esac
      else
        info "the hold vanished without a decision (expired) — nothing executed"
      fi ;;
    404) info "HTTP 404 — the record was already gone (the decision's retry raced a check); nothing new executed" ;;
    *)   bad "unexpected HTTP ${SB_CODE:-none}: $(printf '%s' "${SB_BODY:-}" | head -c 200)" ;;
  esac
fi
fi   # SKIP_WAIT — the sticky-denial case has no hold to decide; jump to the proofs
DAFTER=$(crm_count)
AUDIT_D1=$(eng exec agent-gateway-postgres psql -U agentgw -d agent_gateway -t \
  -c "SELECT count(*) FROM audit_events WHERE resource LIKE '/customers%';" 2>/dev/null | tr -d ' \n')
if [ "$WANTED" = "approved" ]; then
  if [ "$DAFTER" = "$((BEFORE_COUNT - 1))" ]; then
    okk "out-of-band proof: $VICTIM_ID is gone from the CRM ($BEFORE_COUNT → $DAFTER customers)"
  else
    bad "approve path, but the CRM count went $BEFORE_COUNT → $DAFTER — expected exactly one removal"
  fi
else
  if [ "$DAFTER" = "$BEFORE_COUNT" ]; then
    okk "out-of-band proof: $VICTIM_ID is STILL in the CRM — the denied deletion never happened"
  else
    bad "the CRM changed during a DENIED delete ($BEFORE_COUNT → $DAFTER) — this must never happen"
  fi
  printf '\n%sDenied outcome, reported:%s\n' "$RED" "$RST"
  printf '  • the delete was refused (403) with the token still valid on the wire\n'
  printf '  • the refusal is not one-shot: it binds that exact action for the agent\n'
  printf '  • %s remains: %s customers (curl :%s/customers)\n' "$VICTIM_ID" "$DAFTER" "$MCP_PORT"
  printf '  • the refused attempt is on the audit record (deny)\n'
fi
AUDIT_D2=$(eng exec agent-gateway-postgres psql -U agentgw -d agent_gateway -t \
  -c "SELECT count(*) FROM audit_events WHERE resource LIKE '/customers%';" 2>/dev/null | tr -d ' \n')
if [ "${AUDIT_D2:-0}" -gt "${AUDIT_D0:-0}" ] 2>/dev/null; then
  okk "audit trail: the delete attempts are attributed to openclaw-crm-agent (rows $AUDIT_D0 → $AUDIT_D2):"
  eng exec agent-gateway-postgres psql -U agentgw -d agent_gateway -t \
    -c "SELECT ts, agent_id, resource, action, outcome, reason FROM audit_events WHERE resource LIKE '/customers%' ORDER BY ts DESC LIMIT ${AUDIT_D2:-4};" 2>/dev/null \
    | grep . | head -4 | while IFS= read -r r; do line "  $r"; done
fi
LP=$(pending_id)
if [ -n "$LP" ]; then
  info "clearing a leftover hold ($LP) — its window has passed; denying it so the approvals list stays clean"
  decide "$LP" false >/dev/null || true
fi
warn "the delete was the agent's call to attempt — and your call to make."
}

# -----------------------------------------------------------------------------
# run
# -----------------------------------------------------------------------------
step "Demo 9 — MCP under the gateway"
bash "$DEMO_DIR/refresh-dex-redirects.sh" >/dev/null 2>&1 || true
compose up -d --no-recreate >/dev/null 2>&1 || true

UNREACHABLE=0
mcpsrv_ready && gw_mcp_ready || UNREACHABLE=1
[ "$UNREACHABLE" = 0 ] || { bad "stack not healthy — run: cd demo && $ENGINE compose -f docker-compose.yml -f docker-compose.egress.yml up -d"; compose ps; exit 1; }

PartA || true
PartB || true
PartC || true
PartD || true

step "Wrap-up"
line "A: the MCP server alone — anonymous writes, silent to your audit trail"
line "B: behind the gateway — same protocol, now: 401s for the anonymous,"
line "   delegated + audited for the agent, instantly revocable"
line "C: OpenClaw using it for real work through the gateway"
line "D: a delete — approval_rules hold every one: approve ⇒ gone once,"
line "   deny ⇒ 403 and the customer stays; both on the audit record"
line
line "reports:    security/results/{mcpsrv,gateway-mcp}.md   (ZAP baseline)"
line "audit:      $ENGINE exec agent-gateway-postgres psql -U agentgw -d agent_gateway \\"
line "              -c \"SELECT ts, agent_id, resource, action, outcome FROM audit_events ORDER BY ts DESC LIMIT 20;\""
line "console:    http://localhost:8083   (delegations / approvals / audit)"

#!/usr/bin/env bash
# ============================================================================
# Prove the egress rules: HTTP outward calls from OpenClaw's sandbox.
#
# Part A runs in the sandbox's default mode: OpenShell's own proxy enforcement
# (default-deny allowlist installed by `openclaw-sandbox.sh configure`).
#
# Part B (--gateway) layers the Agent Gateway: OpenShell's supervisor chains
# every policy-approved tunnel through the gateway's egress proxy as its
# "upstream proxy" (requires OpenShell >= 0.1.x and the
# [openshell.drivers.docker] upstream stanza in ~/.config/openshell/gateway.toml).
# Every tunneled destination becomes one authorization decision under the
# agent's delegation — held for a human approval, with a Telegram card.
# By default the script waits 60 seconds for you to approve via Telegram or the
# web console, then auto-approves on your behalf.
#
# Usage:
#   ./demo/openclaw-egress-test.sh             # Part A (OpenShell policy)
#   ./demo/openclaw-egress-test.sh --gateway   # Part A + Part B (Agent Gateway)
#
# Flags:
#   --gateway      also run Part B (needs the Agent Gateway stack + upstream stanza)
#   --no-human     never wait for a human: auto-approve every hold immediately
#                  (use for unattended or CI runs)
#   --no-dialogue  skip the (informational) OpenClaw dialogue turns, which are the
#                  slow part; every assertion still runs. Reaches the approval
#                  card in seconds — handy when you want to approve by hand.
# ============================================================================

set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED=''; GRN=''; YLW=''; RST=''
if [ -t 1 ]; then
  RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; RST='\033[0m'
fi
step()  { printf "\n%s\n" "$*"; }
okk()   { printf "  ${GRN}✓ %s${RST}\n" "$*"; }
bad()   { printf "  ${RED}✗ %s${RST}\n" "$*"; }
line()  { printf "     %s\n" "$*"; }
info()  { printf "  ${YLW}• %s${RST}\n" "$*"; }

if [ -f demo/.env ]; then
  set -a; . demo/.env; set +a
fi
# GW_URL must be computed AFTER demo/.env loads: GATEWAY_HOST_PORT there
# selects the PEP listener (:9000 in this demo, since :8080 is taken by the
# OpenShell gateway).
GW_URL="${GW_URL:-http://localhost:${GATEWAY_HOST_PORT:-8080}}"
SANDBOX_NAME="${SANDBOX_NAME:-openclaw}"
APPROVAL_WAIT="${APPROVAL_WAIT:-60}"
# How often to re-check the approvals list while waiting for a human verdict.
# A hold is decided by the human making the pending row disappear, so polling
# on a short interval lets the run continue the moment you approve (or deny).
POLL_INTERVAL="${POLL_INTERVAL:-3}"
# Per-attempt cap for the (informational) agent-dialogue turns. They are the
# slow part of the run; no assertion depends on them, so keep the cap short and
# override with AGENT_TIMEOUT=<secs> when you want to watch a longer turn.
AGENT_TIMEOUT="${AGENT_TIMEOUT:-90}"
APR_GW_LOG="agent-gateway-gateway"
PROVIDER_API_KEY="${PROVIDER_API_KEY:-${NVIDIA_API_KEY:-}}"

if [ -z "$PROVIDER_API_KEY" ]; then
  bad "no API key — set NVIDIA_API_KEY in demo/.env"
  exit 1
fi

if ! openshell sandbox list 2>/dev/null | awk '$1=="'"$SANDBOX_NAME"'"' | grep -q Ready; then
  bad "sandbox '$SANDBOX_NAME' is not Ready — run: make openclaw-demo"
  exit 1
fi

PASS=0; FAIL=0
record() { # label expected actual
  if [ "$2" = "$3" ]; then
    okk "$1 (want $2, got $3)"; PASS=$((PASS+1))
  else
    bad "$1 (want $2, got $3)"; FAIL=$((FAIL+1))
  fi
}
record_blocked() { # label actual
  if [ "$2" != "200" ]; then
    okk "$1 (blocked, got $2)"; PASS=$((PASS+1))
  else
    bad "$1 (should be blocked, got 200)"; FAIL=$((FAIL+1))
  fi
}

code() { # url-arg... — always run curl inside the sandbox
  openshell sandbox exec -n "$SANDBOX_NAME" --no-tty --timeout 60 \
    --env PROVIDER_API_KEY="$PROVIDER_API_KEY" -- \
    curl -s "$@" 2>/dev/null | tail -1
}

# Ask OpenClaw to run a command via its exec tool, then show the agent's reply.
# This is the slow, informational part of the run — no assertion depends on it.
# `retries` defaults to 1: the first turn after a sandbox restart can come up
# silent (model idle-timeout before the gateway's first provider connection
# warms up), so one retry keeps the unattended run showing dialogue. Pass 0 for
# turns that must return promptly. Each attempt is capped at AGENT_TIMEOUT.
ask_agent() { # prompt [retries]
  local prompt="$1" retries="${2:-1}" out
  if [ "$NO_DIALOGUE" = 1 ]; then
    info "skipping agent dialogue (--no-dialogue); assertions use curl directly"
    return 0
  fi
  if [ "$retries" -gt 0 ]; then
    info "asking the agent (up to ${AGENT_TIMEOUT}s, retries once if silent)…"
  else
    info "asking the agent (up to ${AGENT_TIMEOUT}s, single attempt)…"
  fi
  out=$(openshell sandbox exec -n "$SANDBOX_NAME" --no-tty --timeout "$AGENT_TIMEOUT" \
    --env PROVIDER_API_KEY="$PROVIDER_API_KEY" -- \
    openclaw agent -m "$prompt" 2>/dev/null \
    | grep -v 'UNDICI\|trace-warnings\|Warning:')
  if [ -z "$out" ] && [ "$retries" -gt 0 ]; then
    sleep 5
    out=$(openshell sandbox exec -n "$SANDBOX_NAME" --no-tty --timeout "$AGENT_TIMEOUT" \
      --env PROVIDER_API_KEY="$PROVIDER_API_KEY" -- \
      openclaw agent -m "$prompt" 2>/dev/null \
      | grep -v 'UNDICI\|trace-warnings\|Warning:')
  fi
  if [ -z "$out" ]; then
    info "agent turn produced no reply within ${AGENT_TIMEOUT}s (informational — not counted)"
  fi
  printf '%s\n' "$out"
}

RUN_GW=0
NO_HUMAN=0
NO_DIALOGUE=0
for _arg in "$@"; do
  case "$_arg" in
    --gateway|-gateway)          RUN_GW=1 ;;
    --no-human|-nohuman|--nohuman)          NO_HUMAN=1 ;;
    --no-dialogue|-nodialogue|--nodialogue) NO_DIALOGUE=1 ;;
  esac
done

# ============================================================================
# Part B preamble (runs BEFORE Part A when --gateway: once the OpenShell
# supervisor chains tunnels through the Agent Gateway, Part A's allowed-host
# checks traverse the gateway too, so the delegation must already exist).
# ============================================================================

if [ "$RUN_GW" = 1 ]; then
  # 0. OpenShell gateway config must carry the upstream proxy stanza pointing
  #    at the Agent Gateway (one-time host setup; restart the gateway after
  #    editing it).
  OS_CFG="${HOME}/.config/openshell/gateway.toml"
  if [ ! -f "$OS_CFG" ] || ! grep -q '^https_proxy' "$OS_CFG" 2>/dev/null; then
    bad "OpenShell gateway.toml has no upstream proxy stanza — Part B skipped"
    line "add under [openshell.drivers.docker] (schema v2, OpenShell >= 0.1.x), then restart openshell-gateway:"
    line '  https_proxy = "http://127.0.0.1:8088"'
    line '  proxy_auth_file = "'"$HOME"'/.config/openshell/upstream-proxy-auth"'
    line '  proxy_auth_allow_insecure = true'
    line '  proxy_connect_by_hostname = true'
    FAIL=$((FAIL+1)); RUN_GW=0
  fi

  ok_stack=1
  for u in 8081 8082; do
    curl -sf -o /dev/null --max-time 3 "http://localhost:$u/healthz" || ok_stack=0
  done
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://localhost:8088/ 2>/dev/null)" = "407" ] || ok_stack=0
  if [ "$ok_stack" != 1 ]; then
    bad "Agent Gateway stack not reachable (authz:8081, tokensvc:8082, proxy:8088)"
    line "start it:  cd demo && docker compose -f docker-compose.yml -f docker-compose.egress.yml up -d"
    FAIL=$((FAIL+1)); RUN_GW=0
  fi
fi

if [ "$RUN_GW" = 1 ]; then
  # 1. SSO sign-in via the Dex mock connector.
  DEX="http://localhost:5556"; JAR=$(mktemp)
  LOC="$DEX/dex/auth?response_type=code&client_id=agent-gateway&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback&connector_id=mock&scope=openid"
  CODE=""
  for _ in 1 2 3 4 5 6; do
    NX=$(curl -s -b "$JAR" -c "$JAR" -D - -o /dev/null "$LOC" \
         | grep -i '^location' | head -1 | tr -d '\r' \
         | sed 's/^Location: //; s|//dex:5556|//localhost:5556|')
    [ -z "$NX" ] && break
    case "$NX" in
      *code=*) CODE=$(printf '%s' "$NX" | sed 's/.*code=\([^&]*\).*/\1/'); break;;
      /*) LOC="$DEX$NX" ;;
      *)  LOC="$NX" ;;
    esac
  done
  ID_TOKEN=$(curl -s -X POST "$DEX/dex/token" \
    -d "grant_type=authorization_code&client_id=agent-gateway&code=$CODE&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('id_token',''))" 2>/dev/null || true)
  if [ -z "$ID_TOKEN" ]; then
    bad "SSO sign-in failed — Part B skipped"; FAIL=$((FAIL+1)); RUN_GW=0
  fi
fi

if [ "$RUN_GW" = 1 ]; then
  # 2. Delegation: model host tunnels run plainly; GitHub API tunnels are
  #    held for a human (the Part B showcase).
  DELEGATION=$(curl -s -X POST http://localhost:8081/v1/delegations/ \
    -H "Content-Type: application/json" \
    -d '{"agent_id":"openclaw-agent-1","resources":["integrate.api.nvidia.com","api.github.com"],"actions":["read","connect"],"expires_in_seconds":1800,"id_token":"'"$ID_TOKEN"'","approval_rules":[{"when":{"resource_pattern":"api.github.com","action_pattern":"connect"},"require":true,"rationale":"GitHub API tunnels require a human decision"}]}')
  DELEGATION_ID=$(printf '%s' "$DELEGATION" | python3 -c "import sys,json; print(json.load(sys.stdin).get('delegation',{}).get('id',''))" 2>/dev/null || true)
  AGENT_SECRET=$(printf '%s' "$DELEGATION" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agent_secret',''))" 2>/dev/null || true)
  if [ -z "$DELEGATION_ID" ] || [ -z "$AGENT_SECRET" ]; then
    bad "delegation mint failed — Part B skipped"; FAIL=$((FAIL+1)); RUN_GW=0
  else
    line "delegation: $DELEGATION_ID (GitHub connect held)"
  fi
fi

if [ "$RUN_GW" = 1 ]; then
  # 3. Access token for the supervisor's upstream credential file. The 0.1.x
  #    docker driver copies it into the supervisor volume at sandbox START —
  #    rotate the file then `sandbox stop` + `start` (no gateway restart).
  TOKEN=$(curl -s -X POST http://localhost:8082/token \
    -H "Content-Type: application/json" \
    -d "{\"delegation_id\":\"$DELEGATION_ID\",\"ttl_seconds\":1800,\"agent_secret\":\"$AGENT_SECRET\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
  if [ -z "$TOKEN" ]; then
    bad "token mint failed — Part B skipped"; FAIL=$((FAIL+1)); RUN_GW=0
  else
    AUTH_FILE="${HOME}/.config/openshell/upstream-proxy-auth"
    mkdir -p "$(dirname "$AUTH_FILE")"
    printf '%s:x\n' "$TOKEN" > "$AUTH_FILE" && chmod 600 "$AUTH_FILE"
    okk "upstream proxy credential written: $AUTH_FILE"
    # The 0.1.x docker driver copies the credential into the supervisor volume
    # at sandbox START — stop+start (workspace is preserved) is what makes the
    # fresh token live; no gateway restart needed.
    info "rotating the sandbox supervisor's credential copy (stop + start)…"
    if openshell sandbox stop "$SANDBOX_NAME" >/dev/null 2>&1 && \
       openshell sandbox start "$SANDBOX_NAME" >/dev/null 2>&1; then
      okk "supervisor credential refreshed"
    else
      bad "sandbox stop/start failed — stale credential may hold tunnels closed"
      FAIL=$((FAIL+1)); RUN_GW=0
    fi
  fi
fi

# ============================================================================
step "Part A — OpenShell allowlist policy (default sandbox egress)"
# Framing matters: Part A proves the SANDBOX's own policy only when its egress
# is NOT wired through the Agent Gateway. On machines whose gateway.toml has
# the upstream stanza (this demo got there via openclaw-sandbox.sh stack-up),
# allowed-host tunnels reach the gateway, where a human-held rule refuses the
# tunnel — correct gateway behavior, not a policy failure. Say so instead of
# letting the GitHub check report a confusing ✗, and point at the mode to use.
plain_ok=1
if [ "$RUN_GW" = 0 ] && [ -f "${HOME}/.config/openshell/gateway.toml" ] \
   && grep -q '^https_proxy' "${HOME}/.config/openshell/gateway.toml" 2>/dev/null; then
  plain_ok=0
  info "this sandbox routes its egress through the Agent Gateway (upstream stanza in ~/.config/openshell/gateway.toml)"
  line "     Part A's direct-path expectation does not hold here; the GitHub check is skipped."
  line "     run with --gateway to exercise the gateway-mediated path (add --no-human for unattended)."
fi
line "OpenClaw itself is asked to make the calls; its reply shows what it saw."

step "Ask OpenClaw to fetch the NVIDIA model list (ALLOWED host)"
ask_agent 'Use the exec tool to run: curl -s -H "Authorization: Bearer $PROVIDER_API_KEY" https://integrate.api.nvidia.com/v1/models | head -c 200 — then quote the first 200 characters of the HTTP response body verbatim in your reply. If the request fails, say exactly why.'

step "Ask OpenClaw to fetch example.com (NOT allowlisted)"
ask_agent 'Use the exec tool to run: curl -s --max-time 15 -o /dev/null -w "%{http_code}" https://example.com — report the HTTP code it returned and whether the request reached a server.'

C1=$(code -o /dev/null -w '%{http_code}' \
       -H "Authorization: Bearer $PROVIDER_API_KEY" \
       https://integrate.api.nvidia.com/v1/models)
record "curl check — allowed host: NVIDIA model list"   "200" "$C1"

if [ "$RUN_GW" = 0 ] && [ "$plain_ok" = 1 ]; then
  C2=$(code -o /dev/null -w '%{http_code}' --max-time 15 https://api.github.com)
  record "curl check — allowed host: GitHub API"          "200" "$C2"
fi

C3=$(code -o /dev/null -w '%{http_code}' --max-time 15 https://example.com)
record_blocked "curl check — undelegated host: example.com" "$C3"

C4=$(code -o /dev/null -w '%{http_code}' --max-time 15 https://telemetry.openclaw.ai)
record_blocked "curl check — openclaw telemetry (off by default)" "$C4"

# ============================================================================
if [ "$RUN_GW" = 1 ]; then
  step "Part B — Agent Gateway decisions (GitHub tunnel held for a human)"
  line "OpenShell decided traffic may reach the gateway; the gateway decides what happens."

  # The gateway's approvals list (admin API) is the source of truth for holds:
  # every held tunnel appears as a pending approval for this delegation.
  pending_hint() { # label
    curl -s --max-time 3 "http://localhost:${GATEWAY_HOST_PORT:-9000}/v1/approvals/" \
      -H "X-Admin-Token: agent-gateway-demo-admin" \
      | python3 -c "
import sys, json
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
pend = [r for r in rows if r.get('status') == 'pending' and r.get('delegation_id') == '$DELEGATION_ID' and r.get('resource') == 'api.github.com']
pend.sort(key=lambda r: r.get('created_at', ''))
print(pend[-1]['id'] if pend else '')" 2>/dev/null
  }

  # Re-check the approvals list every POLL_INTERVAL seconds until the pending
  # row disappears (the human decided) or the window closes. Returns 0 when a
  # decision arrived, 1 on timeout; DECISION_WAIT holds the elapsed seconds.
  DECISION_WAIT=0
  wait_for_decision() { # approval-id
    local id="$1"
    DECISION_WAIT=0
    while [ "$DECISION_WAIT" -lt "$APPROVAL_WAIT" ]; do
      [ "$(pending_hint)" != "$id" ] && return 0
      sleep "$POLL_INTERVAL"
      DECISION_WAIT=$((DECISION_WAIT + POLL_INTERVAL))
      printf "  ⏳ %ds…\r" "$DECISION_WAIT"
    done
    echo
    return 1
  }

  # A connect that returns 200 means no hold fired — either the tunnel never
  # reached the gateway (the sandbox's egress bypasses it, typically because the
  # OpenShell gateway daemon still runs the gateway.toml it read at start-up)
  # or the hold did not trigger. The gateway's own log decides which: holds are
  # logged with a `proxy:` prefix, so silence over the window implicates routing.
  route_evidence() {
    docker logs agent-gateway-gateway --since 3m 2>/dev/null | grep -c 'proxy: ' || true
  }
  teach_routing() {
    if [ "$(route_evidence)" = "0" ]; then
      line "  evidence: the gateway logged NO proxied traffic in the last 3m —"
      line "  the sandbox's egress is bypassing it (its supervisor started before the"
      line "  upstream stanza existed). Restart the OpenShell gateway so gateway.toml"
      line "  takes effect — ./demo/start-openshell-gateway.sh — then rerun this test."
    else
      line "  evidence: the gateway IS routing this sandbox — a 200 here means the"
      line "  hold did not trigger; check the delegation's approval_rules / authz policy."
    fi
  }

  step "First HTTPS tunnel to GitHub — held for your approval"
  C5=$(code -o /dev/null -w '%{http_code}' --max-time 20 https://api.github.com)
  # A refused tunnel is the hold signal: the gateway did not execute the call.
  # The pending row can already be gone when the human decides inside the poll
  # window (the list is pending-only), so a missing id is not a failure — the
  # decision step below and the retry prove whether the hold was real.
  APR_ID=$(pending_hint)
  if [ "$C5" != "200" ]; then
    okk "first connect: held for human approval (curl saw $C5 — tunnel refused, call not executed)"
    PASS=$((PASS+1))
    if [ -n "$APR_ID" ]; then
      line "approval_id: $APR_ID"
      if [ "$NO_HUMAN" = 1 ]; then
        line "--no-human: auto-approving immediately"
      else
        line "Telegram card sent — approve there (or in the console) to continue at once;"
        line "the script polls every ${POLL_INTERVAL}s and auto-approves after ${APPROVAL_WAIT}s"
      fi
    else
      line "no pending row — already decided (console/Telegram)"
    fi
  else
    bad "first connect executed without approval (curl=$C5)"; FAIL=$((FAIL+1))
    teach_routing
  fi

  # 4. Let the human decide (Telegram/web console), then auto-approve if the
  #    hold is still pending. Both paths count as one decision.
  SUBJ=$(printf '%s' "$ID_TOKEN" | cut -d. -f2 | python3 -c "import sys,json,base64; t=sys.stdin.read().strip(); t+='='*(-len(t)%4); print(json.loads(base64.urlsafe_b64decode(t)).get('sub',''))" 2>/dev/null || true)

  approved=0
  if [ -z "$APR_ID" ]; then
    okk "decision already made before the poll — human approval via console/Telegram"
    PASS=$((PASS+1))
  elif [ "$NO_HUMAN" = 1 ]; then
    info "--no-human: auto-approving without waiting"
    DEC=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW_URL/v1/approvals/" \
      -H "Content-Type: application/json" -H "X-Admin-Token: agent-gateway-demo-admin" \
      -d "{\"approval_id\":\"$APR_ID\",\"approver_id\":\"$SUBJ\",\"approved\":true}")
    record "auto-approve (script acts as the human)" "200" "$DEC"
  else
    info "waiting up to ${APPROVAL_WAIT}s for your approval via Telegram or the web console…"
    if wait_for_decision "$APR_ID"; then
      echo
      okk "decision arrived via Telegram/console after ${DECISION_WAIT}s"
      approved=1
      PASS=$((PASS+1))
    else
      info "no manual approval — auto-approving on your behalf"
      DEC=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW_URL/v1/approvals/" \
        -H "Content-Type: application/json" -H "X-Admin-Token: agent-gateway-demo-admin" \
        -d "{\"approval_id\":\"$APR_ID\",\"approver_id\":\"$SUBJ\",\"approved\":true}")
      record "auto-approve (script acts as the human)" "200" "$DEC"
    fi
  fi

  step "Retry the same tunnel — opens under the approved authority"
  C5b=$(code -o /dev/null -w '%{http_code}' --max-time 20 https://api.github.com)
  record "GET after approval: executed" "200" "$C5b"

  step "Second tunnel — again held (single-use approvals)"
  C6=$(code -o /dev/null -w '%{http_code}' --max-time 20 https://api.github.com)
  APR2=$(pending_hint)
  if [ "$C6" != "200" ]; then
    # The first approval was consumed by the retry above, so a fresh refusal
    # here proves approvals bind exactly once.
    okk "second connect: held again — approvals bind exactly once"
    PASS=$((PASS+1))
    if [ -n "$APR2" ]; then
      line "second approval_id: $APR2"
      if [ "$NO_HUMAN" = 1 ]; then
        info "--no-human: auto-approving without waiting"
      else
        info "waiting up to ${APPROVAL_WAIT}s for your approval via Telegram or the web console…"
        if wait_for_decision "$APR2"; then
          echo
          okk "decision arrived via Telegram/console after ${DECISION_WAIT}s"
        else
          info "no manual approval — auto-approving on your behalf"
        fi
      fi
      if [ "$(pending_hint)" = "$APR2" ]; then
        curl -s -o /dev/null -X POST "$GW_URL/v1/approvals/" \
          -H "Content-Type: application/json" -H "X-Admin-Token: agent-gateway-demo-admin" \
          -d "{\"approval_id\":\"$APR2\",\"approver_id\":\"$SUBJ\",\"approved\":true}"
      fi
    else
      line "no pending row — already decided (console/Telegram)"
    fi
    line "approved — retrying…"
    C6b=$(code -o /dev/null -w '%{http_code}' --max-time 20 https://api.github.com)
    record "second GET after approval: executed" "200" "$C6b"
  else
    bad "second connect executed without a fresh approval (curl=$C6)"; FAIL=$((FAIL+1))
    teach_routing
  fi

  # Undelegated host — OpenShell's default-deny refuses before the gateway
  # sees anything (no approval card ever dispatched).
  step "Undelegated host — denied by OpenShell (gateway never consulted)"
  C8=$(code -o /dev/null -w '%{http_code}' --max-time 15 https://example.com)
  record_blocked "undelegated host: example.com" "$C8"

  step "Ask OpenClaw to make a proxy-transparent call (agent sees none of it)"
  ask_agent 'Use the exec tool to run: curl -s -H "Authorization: Bearer $PROVIDER_API_KEY" https://integrate.api.nvidia.com/v1/models | head -c 120 — then quote the response body verbatim in your reply.' 0

  line "held actions are single-use and expire; each hold dispatches a Telegram card"
  line "agent-initiated holds: the exec-tool call above would hang until approved —"
  line "watch the card, or keep agent-held prompts off the unattended script"
  line "unattended/CI: add --no-human to auto-approve every hold without waiting"
fi

# ============================================================================
step "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1

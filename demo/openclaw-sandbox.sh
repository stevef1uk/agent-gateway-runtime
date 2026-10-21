#!/usr/bin/env bash
# ============================================================================
# Run OpenClaw inside an NVIDIA OpenShell sandbox.
#
# OpenShell is the isolation boundary: the whole OpenClaw process runs as an
# unprivileged user in a container with no host filesystem, no Docker socket,
# and default-deny egress. This script builds the image, launches the sandbox,
# and gives you a chat interface.
#
# Usage:
#   ./demo/openclaw-sandbox.sh build        # build the image only
#   ./demo/openclaw-sandbox.sh up           # build + create the sandbox (gateway)
#   ./demo/openclaw-sandbox.sh chat "hi"    # send one message (starts sandbox if needed)
#   ./demo/openclaw-sandbox.sh shell        # interactive shell inside the sandbox
#   ./demo/openclaw-sandbox.sh status       # sandbox + gateway status
#   ./demo/openclaw-sandbox.sh down         # delete the sandbox
#
# Model provider (one-time, before chat):
#   NVIDIA_API_KEY=nvapi-... ./demo/openclaw-sandbox.sh configure
#   # or point at any OpenAI-compatible endpoint:
#   PROVIDER_BASE_URL=https://... PROVIDER_API_KEY=... PROVIDER_MODEL=... \
#     ./demo/openclaw-sandbox.sh configure
#
# Notes:
#   - the sandbox is default-deny for egress. `configure` also allowlists the
#     provider + OpenClaw catalog endpoints so the model call can leave. The
#     sandbox routes egress through OpenShell's HTTP proxy (HTTPS_PROXY is
#     pre-set inside the sandbox), so the allowlist is the control point.
#   - the API key is stored as an env SecretRef inside the sandbox's own
#     /sandbox/.openclaw config, and is only injected into the `exec` env for
#     commands that need it. It is not written on the host or baked in the image.
# ============================================================================

set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED=''; GRN=''; YLW=''; BLU=''; BLD=''; RST=''
if [ -t 1 ]; then
  RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; BLU='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
fi
step() { printf "\n${BLD}${BLU}%s${RST}\n" "$*"; }
okk()  { printf "  ${GRN}✓ %s${RST}\n" "$*"; }
bad()  { printf "  ${RED}✗ %s${RST}\n" "$*"; }
warn() { printf "  ${YLW}• %s${RST}\n" "$*"; }
line() { printf "  %s\n" "$*"; }

IMAGE="${IMAGE:-agent-gateway-demo/openclaw:latest}"
SANDBOX_NAME="${SANDBOX_NAME:-openclaw}"
GATEWAY_PORT="${GATEWAY_PORT:-18789}"

# Load demo/.env if present (do not override vars already in the environment).
if [ -f demo/.env ]; then
  set -a
  # shellcheck disable=SC1091
  . demo/.env
  set +a
fi

# Provider defaults: NVIDIA's OpenAI-compatible endpoint.
# PROVIDER_MODEL is the BARE model id (no provider prefix). OpenClaw prefixes
# the provider key ("nvidia") onto it when building the agent model reference.
PROVIDER_BASE_URL="${PROVIDER_BASE_URL:-https://integrate.api.nvidia.com/v1}"
PROVIDER_MODEL="${PROVIDER_MODEL:-nvidia/nemotron-3.5-lightning-30b-a3b}"
# Model-turn ceiling ("idle timeout") written into the sandbox's OpenClaw
# config during `configure`. A reasoning model's first turn after the sandbox
# restarts (credential rotation) is cold and can exceed the default, so raise
# the ceiling by default and let the environment express doubt.
PROVIDER_TIMEOUT_SECONDS="${PROVIDER_TIMEOUT_SECONDS:-240}"
PROVIDER_API_KEY="${PROVIDER_API_KEY:-${NVIDIA_API_KEY:-}}"

have() { command -v "$1" >/dev/null 2>&1; }

if ! have openshell; then
  bad "openshell CLI is not on PATH. Install OpenShell first: https://docs.nvidia.com/openshell/latest"
  exit 1
fi
if ! have docker && ! have podman; then
  bad "neither docker nor podman is on PATH (needed to build the image for the local gateway)."
  exit 1
fi

# Docker or Podman — see lib/engine.sh (CONTAINER_ENGINE env override).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/engine.sh"

sandbox_exists() {
  openshell sandbox list 2>/dev/null | awk '{print $1}' | grep -qx "$SANDBOX_NAME"
}
sandbox_ready() {
  openshell sandbox list 2>/dev/null | awk -v n="$SANDBOX_NAME" '
    $1==n {
      if ($0 ~ /Ready/) { found=1; exit 0 }
      found=1; exit 1
    }
    END { if(!found) exit 1 }
  '
}

build() {
  step "Build the OpenClaw image"
  eng build -t "$IMAGE" demo/openclaw
  okk "image built: $IMAGE"
}

ensure_sandbox() {
  if sandbox_exists && sandbox_ready; then
    return 0
  fi
  if sandbox_exists; then
    local phase
    # Phase is the LAST column of `sandbox list` (the row is NAME CREATED TIME
    # PHASE — column 2 is the created date, not the phase).
    phase=$(openshell sandbox list 2>/dev/null | awk -v n="$SANDBOX_NAME" '$1==n {print $NF}')
    # Completed = the canonical main process exited (e.g. the in-sandbox
    # OpenClaw gateway received Ctrl-C), and with the default restart policy
    # it will never become Ready again. Error and any other non-Ready phase
    # get the same treatment: delete, then recreate below.
    warn "sandbox '$SANDBOX_NAME' exists but is not Ready (phase: $phase) — recreating"
    openshell sandbox delete "$SANDBOX_NAME" >/dev/null 2>&1 || true
  fi
  step "Create the OpenShell sandbox (OpenClaw gateway in the foreground)"
  # OpenShell replaces the image entrypoint with its supervisor, then runs the
  # command after `--`. `gateway run` keeps OpenClaw alive in the foreground.
  #
  # Three things matter here:
  #   1. --allow-unconfigured: without it the gateway refuses to boot against
  #      our pre-seeded (minimal) config and exits 78. The flag just skips
  #      full-onboarding validation; the baked model config still applies.
  #   2. SQLITE_TMPDIR=/tmp: the gateway runs under OpenShell's Landlock
  #      filesystem sandbox. SQLite needs a writable temp dir to create FTS5
  #      shadow tables for the agent transcript DB; without this the first
  #      chat turn fails with "fts5: ... unable to open database file".
  #   3. PROVIDER_API_KEY in the *gateway's* env: the gateway process is the
  #      one that makes the model call, so it must be able to resolve the
  #      env SecretRef in the provider config.
  #   4. --detach: without it, `sandbox create` ATTACHES to the canonical main
  #      process (the in-sandbox OpenClaw gateway) whenever the caller has a
  #      terminal — verified on openshell 0.1.4 under a pty — so `up` streams
  #      the gateway banner forever, and Ctrl-C SIGINTs the gateway, leaving
  #      the sandbox Phase=Completed. --detach keeps create returning on any
  #      terminal; wait_for_gateway below already handles the readiness race.
  #
  # We deliberately do NOT pass --forward: that flag keeps the foreground
  # `sandbox create` attached to hold an SSH tunnel, so the command never
  # returns. Chat/status/shell all reach the sandbox via `sandbox exec`.
  local create_env=(--env SQLITE_TMPDIR=/tmp)
  if [ -n "$PROVIDER_API_KEY" ]; then
    create_env+=(--env "PROVIDER_API_KEY=${PROVIDER_API_KEY}")
  fi
  openshell sandbox create \
    --detach \
    --name "$SANDBOX_NAME" \
    --from "$IMAGE" \
    "${create_env[@]}" \
    -- openclaw gateway run --bind loopback --allow-unconfigured
  okk "sandbox '$SANDBOX_NAME' is up (OpenClaw gateway on :$GATEWAY_PORT inside the sandbox)"
}

configure() {
  ensure_sandbox
  if [ -z "$PROVIDER_API_KEY" ]; then
    bad "no API key. Set NVIDIA_API_KEY or PROVIDER_API_KEY and rerun 'configure'."
    exit 1
  fi
  step "Configure the model provider inside the sandbox"

  # Write the OpenClaw config directly rather than via `openclaw config set`:
  # the CLI keeps a runtime snapshot that can go stale, and it rejects a
  # straight model-list replace. Writing the file is deterministic.
  #
  # Two things matter here:
  #   - the stored model `id`/`name` must be the BARE id (no provider prefix),
  #     because OpenClaw prefixes the provider key ("nvidia") onto it when it
  #     builds the API request. Getting this backwards sends "nvidia/nvidia/...".
  #   - the API key is an env SecretRef: only the env var *name* is stored,
  #     never the secret. The gateway process must have PROVIDER_API_KEY in
  #     its env (the create step injects it).
  local provider_id="nvidia"
  # PROVIDER_MODEL is the BARE model id (no provider prefix). OpenClaw prefixes
  # it with the provider id — but only when it contains no slash itself:
  # NVIDIA catalog ids like meta/llama-3.2-11b-vision-instruct already carry
  # their own namespace, and nvidia/meta/... would 404.
  local model_ref="${PROVIDER_MODEL}"
  case "${PROVIDER_MODEL}" in */*) ;; *) model_ref="${provider_id}/${PROVIDER_MODEL}" ;; esac
  local config_json
  config_json=$(printf '%s' "{
    \"models\": {\"providers\": {\"${provider_id}\": {
        \"baseUrl\": \"${PROVIDER_BASE_URL}\",
        \"apiKey\": {\"source\": \"env\", \"provider\": \"default\", \"id\": \"PROVIDER_API_KEY\"},
        \"models\": [{
          \"id\": \"${PROVIDER_MODEL}\",
          \"name\": \"${PROVIDER_MODEL}\",
          \"contextWindow\": 131072,
          \"maxTokens\": 4096
        }],
        \"timeoutSeconds\": ${PROVIDER_TIMEOUT_SECONDS}
    }}},
    \"agents\": {\"defaults\": {\"model\": \"${model_ref}\", \"timeoutSeconds\": ${PROVIDER_TIMEOUT_SECONDS}}}
  }")

  # Base64 avoids any shell/quoting hazards writing the JSON inside the sandbox.
  printf '%s' "$config_json" | openshell sandbox exec -n "$SANDBOX_NAME" --no-tty -- \
    sh -c 'umask 077; cat > /sandbox/.openclaw/openclaw.json; echo "config written"'

  # Allow only the provider + OpenClaw catalog hosts out of the sandbox.
  #    NOTE: no `::tcp` suffix. The sandbox routes egress through OpenShell's
  #    HTTP proxy (HTTPS_PROXY is pre-set in the sandbox env), which uses the
  #    substrate that is already running. `::tcp` would demand the transparent
  #    TCP substrate, which must be enabled at sandbox creation.
  local provider_host
  provider_host=$(printf '%s' "$PROVIDER_BASE_URL" | sed -E 's#^https?://##; s#/.*##; s#:.*##')
  line "applying the egress allowlist (4 endpoints, each confirmed by a policy wait — can take up to a minute)"
  apply_egress_rule "$provider_host"
  apply_egress_rule "catalog.openclaw.ai"
  apply_egress_rule "clawhub.ai"
  apply_egress_rule "api.github.com"

  okk "provider configured: $PROVIDER_BASE_URL (model: $model_ref)"
  line "credential is an env SecretRef in the sandbox — not on the host, not in the image"
}

apply_egress_rule() {
  local host="$1"
  openshell policy update "$SANDBOX_NAME" \
    --rule-name openclaw_egress \
    --binary /usr/bin/bash \
    --binary /usr/bin/node \
    --binary /usr/bin/curl \
    --binary /usr/local/bin/node \
    --binary /usr/local/bin/openclaw \
    --add-endpoint "${host}:443" \
    --wait >/dev/null 2>&1 || warn "could not add egress rule for $host (may already be present)"
}

# ----------------------------------------------------------------------------
# Agent Gateway (layered demo)
#
# The OpenShell supervisor can chain every outbound tunnel through the Agent
# Gateway on the host, which is where the approval decisions happen. Three
# pieces have to line up on this machine:
#   1. the demo stack is up (egress proxy published on :8088);
#   2. the proxy's Basic source allowlist matches the network this host's
#      supervisor reaches it from (varies by engine — Linux bridge, Docker
#      Desktop VM, ...);
#   3. the supervisor holds a live Agent Gateway access token.
# ----------------------------------------------------------------------------

stack_up() {
  # Bring the Agent Gateway stack up with the egress overlay (idempotent).
  step "Agent Gateway stack (base compose + egress overlay)"
  # Register this machine's console URIs in the dex client first (no-op when
  # already listed) so browser sign-in works on a fresh clone/Mac.
  bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/refresh-dex-redirects.sh" || true
  compose -f demo/docker-compose.yml -f demo/docker-compose.egress.yml up -d
  okk "stack up (egress proxy on :8088)"
}

# Read PROXY_BASIC_AUTH_CIDRS out of demo/.env (empty when unset).
proxy_cidrs() {
  grep '^PROXY_BASIC_AUTH_CIDRS=' demo/.env 2>/dev/null | tail -1 | cut -d= -f2- || true
}

ensure_proxy_basic_auth() {
  # Work out what PROXY_BASIC_AUTH_CIDRS must be on THIS machine and make sure
  # demo/.env carries it.
  #
  # The value is measured, not guessed: the gateway's 407 names the exact
  # source IP it saw, so a probe with a junk Basic credential tells us where to
  # point. Then:
  #   "not permitted from <ip>" -> allow <ip>/24 and retry (gateway recreated)
  #   "is disabled"             -> the egress overlay was not applied
  #   anything else             -> the source gate passed (the token itself was
  #                                 what got rejected), which is the outcome we
  #                                 are checking for
  local current
  current=$(proxy_cidrs)
  [ -z "$current" ] && current="127.0.0.0/8,::1/128,172.16.0.0/12"
  # Docker Desktop resolves the host as the host-gateway IP from its VM.
  if [ "$(uname -s)" = "Darwin" ]; then
    case ",$current," in
      *,192.168.65.0/24,*) ;;
      *) current="$current,192.168.65.0/24" ;;
    esac
  fi

  step "Checking the Agent Gateway's Basic-auth source allowlist"
  local probe cidr round
  for round in 1 2 3 4; do
    probe=$(curl -s --max-time 6 --proxy http://127.0.0.1:8088 http://example.com/ \
      -H "Proxy-Authorization: Basic $(printf 'junk:x' | base64)" 2>/dev/null || true)
    case "$probe" in
      *"not permitted from "*)
        local peer
        peer=$(printf '%s' "$probe" | sed -n 's/.*not permitted from \([0-9A-Fa-f.:]*\).*/\1/p')
        if [ -z "$peer" ]; then
          bad "could not read the gateway's source IP from: $(printf '%s' "$probe" | head -c 160)"
          return 1
        fi
        case "$peer" in
          *:*) cidr="$(printf '%s' "$peer" | cut -d: -f1-4)::/64" ;;
          *)   cidr="$(printf '%s' "$peer" | cut -d. -f1-3).0/24" ;;
        esac
        case ",$current," in
          *",$cidr,"*)
            # The measured peer CIDR is already allowlisted but the gateway
            # still denies it — the running container is almost certainly
            # carrying a stale env (started before the list was correct).
            # Recreating with the current list is cheap and bounded by the
            # loop below; only after the rounds are exhausted do we give up.
            line "gateway still denies $peer although $cidr is already allowlisted —"
            line "recreating the gateway container (stale allowlist in its env)"
            ;;

          *)
            line "gateway sees this host as $peer — allowing $cidr"
            current="$current,$cidr"
            ;;
        esac
        ;;
      *"is disabled"*)
        bad "Basic proxy auth is disabled on the gateway — the egress overlay sets PROXY_BASIC_AUTH=1"
        line "rerun: $ENGINE compose -f demo/docker-compose.yml -f demo/docker-compose.egress.yml up -d"
        return 1
        ;;
      *)
        # Source gate passed; the junk credential is what got rejected.
        if [ "$current" != "$(proxy_cidrs)" ]; then
          if grep -q '^PROXY_BASIC_AUTH_CIDRS=' demo/.env 2>/dev/null; then
            sed -i.bak 's|^PROXY_BASIC_AUTH_CIDRS=.*|PROXY_BASIC_AUTH_CIDRS='"$current"'|' demo/.env
            rm -f demo/.env.bak
          else
            printf 'PROXY_BASIC_AUTH_CIDRS=%s\n' "$current" >> demo/.env
          fi
          PROXY_BASIC_AUTH_CIDRS="$current"
          okk "PROXY_BASIC_AUTH_CIDRS written to demo/.env: $current"
        else
          okk "PROXY_BASIC_AUTH_CIDRS is correct for this machine: $current"
        fi
        return 0
        ;;
    esac

    # Recreate the gateway with the wider source list, then probe again.
    PROXY_BASIC_AUTH_CIDRS="$current" \
      compose -f demo/docker-compose.yml -f demo/docker-compose.egress.yml up -d gateway >/dev/null
    sleep 2
  done
  bad "could not confirm the Basic-auth source allowlist"
  line "expected 'not permitted from <ip>' or a token rejection; got: $(printf '%s' "$probe" | head -c 160)"
  return 1
}

# Echo the token currently sitting in the supervisor's upstream credential
# file (empty when there is none). Always returns 0 so it is safe under -e.
gateway_token_state() {
  local f="${HOME}/.config/openshell/upstream-proxy-auth"
  if [ -f "$f" ]; then
    head -c 128 "$f" | cut -d: -f1
  fi
  return 0
}

ensure_gateway_token() {
  # Mint an Agent Gateway credential for this sandbox's supervisor: mock SSO →
  # delegation → access token, written to the file the OpenShell driver copies
  # into the supervisor volume at sandbox START.
  #
  # A no-op when the host's OpenShell config has no upstream stanza (the plain
  # sandbox path, where egress is governed by OpenShell policy alone).
  local os_cfg="${HOME}/.config/openshell/gateway.toml"
  if [ ! -f "$os_cfg" ] || ! grep -q '^https_proxy' "$os_cfg" 2>/dev/null; then
    warn "OpenShell gateway.toml has no upstream stanza — no Agent Gateway hop for this sandbox"
    return 0
  fi
  if ! curl -sf -o /dev/null --max-time 3 http://localhost:8081/healthz; then
    bad "Agent Gateway authz is not reachable on :8081"
    line "start the demo stack first: $ENGINE compose -f demo/docker-compose.yml -f demo/docker-compose.egress.yml up -d"
    exit 1
  fi

  local auth_file="${HOME}/.config/openshell/upstream-proxy-auth"
  local meta="${auth_file}.meta"
  mkdir -p "$(dirname "$auth_file")"

  # Reuse a credential that has not expired: minting forces a supervisor
  # restart, which a second chat in the same session does not need. The
  # recorded checksum stops the reuse if anything else rewrote the credential
  # file (the egress test mints its own).
  if [ -s "$auth_file" ] && [ -f "$meta" ]; then
    local expires want crc
    read -r expires want < "$meta" || expires=0
    case "$expires" in ''|*[!0-9]*) expires=0 ;; esac
    crc=$(cksum < "$auth_file" 2>/dev/null | awk '{print $1}')
    if [ -n "$want" ] && [ "$want" = "$crc" ] \
       && [ "$(date +%s)" -lt "$((expires - 60))" ]; then
      okk "reusing the live Agent Gateway credential"
      return 0
    fi
  fi

  step "Agent Gateway credential (mock SSO → delegation → access token)"
  local DEX="http://localhost:5556" JAR LOC CODE NX ID_TOKEN
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
  ID_TOKEN=$(curl -s -X POST "$DEX/dex/token" \
    -d "grant_type=authorization_code&client_id=agent-gateway&code=$CODE&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('id_token',''))" 2>/dev/null || true)
  if [ -z "$ID_TOKEN" ]; then
    bad "mock SSO sign-in failed (Dex on :5556)"
    exit 1
  fi

  # Delegation: model-host tunnels run plainly so the chat's POSTs flow;
  # genuinely risky outbound (GitHub connects) holds for a human.
  local DELEGATION DELEGATION_ID AGENT_SECRET TOKEN
  DELEGATION=$(curl -s -X POST http://localhost:8081/v1/delegations/ \
    -H "Content-Type: application/json" \
    -d '{"agent_id":"openclaw-agent-1","resources":["integrate.api.nvidia.com","api.github.com"],"actions":["read","connect"],"expires_in_seconds":1800,"id_token":"'"$ID_TOKEN"'","approval_rules":[{"when":{"resource_pattern":"api.github.com","action_pattern":"connect"},"require":true,"rationale":"GitHub API tunnels require a human decision"}]}')
  DELEGATION_ID=$(printf '%s' "$DELEGATION" | python3 -c "import sys,json; print(json.load(sys.stdin).get('delegation',{}).get('id',''))" 2>/dev/null || true)
  AGENT_SECRET=$(printf '%s' "$DELEGATION" | python3 -c "import sys,json; print(json.load(sys.stdin).get('agent_secret',''))" 2>/dev/null || true)
  if [ -z "$DELEGATION_ID" ] || [ -z "$AGENT_SECRET" ]; then
    bad "delegation mint failed: $(printf '%s' "$DELEGATION" | head -c 200)"
    exit 1
  fi
  line "delegation: $DELEGATION_ID (api.github.com connect held for a human)"

  TOKEN=$(curl -s -X POST http://localhost:8082/token \
    -H "Content-Type: application/json" \
    -d "{\"delegation_id\":\"$DELEGATION_ID\",\"ttl_seconds\":1800,\"agent_secret\":\"$AGENT_SECRET\"}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
  if [ -z "$TOKEN" ]; then
    bad "access token mint failed (tokensvc on :8082)"
    exit 1
  fi

  local before
  before=$(gateway_token_state)
  printf '%s:x\n' "$TOKEN" > "$auth_file"
  chmod 600 "$auth_file"
  printf '%s %s\n' "$(( $(date +%s) + 1800 ))" \
    "$(cksum < "$auth_file" | awk '{print $1}')" > "$meta"
  chmod 600 "$meta"
  if [ "$before" != "$TOKEN" ] && sandbox_exists; then
    # The 0.1.x docker driver copies the credential into the supervisor volume
    # at sandbox START — stop+start (workspace preserved) is what makes a fresh
    # token live. No gateway restart needed.
    line "refreshing the supervisor's credential copy (sandbox stop + start)"
    openshell sandbox stop "$SANDBOX_NAME" >/dev/null 2>&1 || true
    openshell sandbox start "$SANDBOX_NAME" >/dev/null 2>&1 || true
  fi
  okk "upstream proxy credential written: $auth_file"
}

# Poll until the in-sandbox OpenClaw gateway answers on :$GATEWAY_PORT.
# `sandbox create` and (in ensure_gateway_token) stop+start both return before
# the gateway process has bound its port, so an immediate agent turn races it
# and dies with ECONNREFUSED on ws://127.0.0.1:$GATEWAY_PORT. Bounded wait;
# returns non-zero if it never comes up, letting the caller surface the failure.
wait_for_gateway() {
  local tries="${GATEWAY_WAIT_TRIES:-30}" i=0
  while [ "$i" -lt "$tries" ]; do
    if openshell sandbox exec -n "$SANDBOX_NAME" --no-tty -- \
        sh -c 'curl -sf http://127.0.0.1:'"$GATEWAY_PORT"'/healthz >/dev/null' 2>/dev/null; then
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  warn "OpenClaw gateway not answering on :$GATEWAY_PORT after $((tries * 2))s"
  return 1
}

# One agent turn. The model call is made by the in-sandbox gateway process, so
# the key rides in the exec environment (env SecretRef).
run_agent() {
  local msg="$1"
  step "Chat with OpenClaw"
  line "a cold first turn (reasoning model, provider warm-up) can take minutes — up to ${AGENT_TIMEOUT:-300}s; silence here is waiting, not hanging"
  if ! wait_for_gateway; then
    bad "OpenClaw gateway is not reachable inside the sandbox"
    exit 1
  fi
  # Capture the turn so timeouts can be recognised and then explained: hitting
  # the model idle timeout is the normal first-turn failure on a cold provider
  # (the reasoning model is slow to warm up), not a broken setup.
  local rc=0 turn_out
  turn_out=$(mktemp)
  if [ -n "$PROVIDER_API_KEY" ]; then
    openshell sandbox exec -n "$SANDBOX_NAME" --no-tty --timeout "${AGENT_TIMEOUT:-300}" \
      --env PROVIDER_API_KEY="$PROVIDER_API_KEY" -- \
      openclaw agent -m "$msg" 2>&1 | tee "$turn_out" || rc=${PIPESTATUS[0]}
  else
    # Key already configured in a prior `configure` run lives in the sandbox
    # state; still inject if the user exported it now.
    openshell sandbox exec -n "$SANDBOX_NAME" --no-tty --timeout "${AGENT_TIMEOUT:-300}" -- \
      openclaw agent -m "$msg" 2>&1 | tee "$turn_out" || rc=${PIPESTATUS[0]}
  fi
  if [ "$rc" -ne 0 ] && grep -qiE "idle timeout|did not produce a response" "$turn_out"; then
    warn "the model turn hit its idle timeout (OpenClaw saw no response in time)"
    line "  why:  the first turn after the sandbox's credential rotation is a cold"
    line "        provider start, and the default model is a reasoning model — slow to answer"
    line "  what: turning the model call short; nothing else in the setup is broken"
    line "  try:  RERUN the same command — the second turn is warm and fast; or pick a"
    line "        faster model for the demo: PROVIDER_MODEL=<id> ./demo/openclaw-sandbox.sh configure"
    line "  fix:  ./demo/openclaw-sandbox.sh configure   (writes a ${PROVIDER_TIMEOUT_SECONDS}s ceiling;"
    line "          raise it: PROVIDER_TIMEOUT_SECONDS=600 ./demo/openclaw-sandbox.sh configure)"
  elif [ "$rc" -ne 0 ]; then
    warn "the agent turn failed (exit $rc) — output above is the raw provider answer"
  fi
  rm -f "$turn_out"
  return "$rc"
}

chat() {
  local msg="$*"
  if [ -z "$msg" ]; then
    bad "no message. Usage: ./demo/openclaw-sandbox.sh chat \"your message\""
    exit 1
  fi
  ensure_sandbox
  # Docker re-picks the compose subnet whenever the network is recreated
  # (fresh install, eng restart, down/up), and the gateway's Basic-auth
  # source allowlist is expressed as a CIDR of the subnet's gateway IP — a
  # stale .env then silently 407s every proxied CONNECT and the chat's model
  # call hangs. Measure the allowlist per machine on every chat path, not
  # just chat-gateway (chat_gateway does the same a step earlier).
  ensure_proxy_basic_auth || warn "Basic-auth source check failed — egress may refuse this sandbox (see above)"
  ensure_gateway_token
  run_agent "$msg"
}

# Same as chat, but first brings up the layered demo: the Agent Gateway stack,
# this machine's Basic-auth source allowlist, and the supervisor's gateway
# credential.
chat_gateway() {
  local msg="$*"
  if [ -z "$msg" ]; then
    bad "no message. Usage: ./demo/openclaw-sandbox.sh chat-gateway \"your message\""
    exit 1
  fi
  stack_up
  ensure_proxy_basic_auth
  ensure_sandbox
  ensure_gateway_token
  run_agent "$msg"
}

shell() {
  ensure_sandbox
  step "Interactive shell inside the sandbox (exit to leave; sandbox keeps running)"
  openshell sandbox connect -n "$SANDBOX_NAME"
}

status() {
  step "Sandbox status"
  openshell sandbox list 2>/dev/null || true
  if sandbox_exists && sandbox_ready; then
    okk "sandbox '$SANDBOX_NAME' is Ready"
    step "OpenClaw gateway health (checked from inside the sandbox)"
    if openshell sandbox exec -n "$SANDBOX_NAME" --no-tty -- \
        sh -c 'curl -sf http://127.0.0.1:'"$GATEWAY_PORT"'/healthz >/dev/null' 2>/dev/null; then
      okk "gateway answering on :$GATEWAY_PORT (inside the sandbox)"
    else
      warn "gateway not answering on :$GATEWAY_PORT yet (may still be starting)"
    fi
  else
    warn "sandbox '$SANDBOX_NAME' is not running. Start it with: ./demo/openclaw-sandbox.sh up"
  fi
}

down() {
  step "Delete the sandbox"
  if sandbox_exists; then
    openshell sandbox delete "$SANDBOX_NAME"
    okk "sandbox '$SANDBOX_NAME' deleted"
  else
    warn "no sandbox named '$SANDBOX_NAME'"
  fi
}

restart() {
  down
  ensure_sandbox
  status
  configure
}

case "${1:-}" in
  build)           build ;;
  up)              build; ensure_sandbox; status ;;
  stack-up)        stack_up; ensure_proxy_basic_auth ;;
  configure)       configure ;;
  chat)            shift; chat "$@" ;;
  chat-gateway)    shift; chat_gateway "$@" ;;
  shell)           shell ;;
  status)          status ;;
  down)            down ;;
  restart)         restart ;;
  *)
    cat <<EOF
 Usage: ./demo/openclaw-sandbox.sh <command>

  build                     Build the OpenClaw image
  up                        Build + launch the sandbox (OpenClaw gateway)
  stack-up                  Start the Agent Gateway stack + set this machine's
                            Basic-auth source allowlist (PROXY_BASIC_AUTH_CIDRS)
  configure                 Set the model provider + allow egress (needs a key)
  chat "message"            Send one message to the agent
  chat-gateway "message"    Same, but layers the Agent Gateway (stack, allowlist,
                            supervisor credential) first
  shell                     Interactive shell inside the sandbox
  status                    Sandbox + gateway status
  down                      Delete the sandbox
  restart                   Delete + recreate + configure (fixes stale sessions)

Provider (for configure):
  NVIDIA_API_KEY=nvapi-... ./demo/openclaw-sandbox.sh configure
  PROVIDER_BASE_URL=... PROVIDER_API_KEY=... PROVIDER_MODEL=... ./demo/openclaw-sandbox.sh configure
EOF
    ;;
esac

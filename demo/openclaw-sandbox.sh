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
PROVIDER_MODEL="${PROVIDER_MODEL:-nemotron-3-super-120b-a12b}"
PROVIDER_API_KEY="${PROVIDER_API_KEY:-${NVIDIA_API_KEY:-}}"

have() { command -v "$1" >/dev/null 2>&1; }

if ! have openshell; then
  bad "openshell CLI is not on PATH. Install OpenShell first: https://docs.nvidia.com/openshell/latest"
  exit 1
fi
if ! have docker; then
  bad "docker is not on PATH (needed to build the image for the local gateway)."
  exit 1
fi

sandbox_exists() {
  openshell sandbox list 2>/dev/null | awk '{print $1}' | grep -qx "$SANDBOX_NAME"
}
sandbox_ready() {
  openshell sandbox list 2>/dev/null | awk -v n="$SANDBOX_NAME" '
    $1==n {
      if ($0 ~ /Error/) { print 1; found=1; exit 1 }
      if ($0 ~ /Ready/) { print 0; found=1; exit 0 }
      if ($0 ~ /Completed/) { print 1; found=1; exit 1 }
      print 1; found=1; exit 1
    }
    END { if(!found) exit 1 }
  '
}

build() {
  step "Build the OpenClaw image"
  docker build -t "$IMAGE" demo/openclaw
  okk "image built: $IMAGE"
}

ensure_sandbox() {
  if sandbox_exists && sandbox_ready; then
    return 0
  fi
  if sandbox_exists; then
    local phase
    phase=$(openshell sandbox list 2>/dev/null | awk -v n="$SANDBOX_NAME" '$1==n {print $2}')
    if [ "$phase" = "Error" ]; then
      warn "sandbox '$SANDBOX_NAME' is in Error state — recreating"
      openshell sandbox delete "$SANDBOX_NAME" >/dev/null 2>&1 || true
    elif [ "$phase" = "Completed" ]; then
      warn "sandbox '$SANDBOX_NAME' is in Completed state — waiting for Ready"
      local retries=30
      while [ $retries -gt 0 ]; do
        sleep 2
        phase=$(openshell sandbox list 2>/dev/null | awk -v n="$SANDBOX_NAME" '$1==n {print $2}')
        if [ "$phase" = "Ready" ]; then
          return 0
        elif [ "$phase" = "Error" ]; then
          warn "sandbox transitioned to Error — recreating"
          openshell sandbox delete "$SANDBOX_NAME" >/dev/null 2>&1 || true
          break
        fi
        retries=$((retries - 1))
      done
      if [ $retries -eq 0 ]; then
        bad "sandbox '$SANDBOX_NAME' did not become Ready in time"
        exit 1
      fi
    else
      warn "sandbox '$SANDBOX_NAME' exists but is not Ready (phase: $phase) — recreating"
      openshell sandbox delete "$SANDBOX_NAME" >/dev/null 2>&1 || true
    fi
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
  #
  # We deliberately do NOT pass --forward: that flag keeps the foreground
  # `sandbox create` attached to hold an SSH tunnel, so the command never
  # returns. Chat/status/shell all reach the sandbox via `sandbox exec`.
  local create_env=(--env SQLITE_TMPDIR=/tmp)
  if [ -n "$PROVIDER_API_KEY" ]; then
    create_env+=(--env "PROVIDER_API_KEY=${PROVIDER_API_KEY}")
  fi
  openshell sandbox create \
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
  local model_ref="${provider_id}/${PROVIDER_MODEL}"
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
        }]
    }}},
    \"agents\": {\"defaults\": {\"model\": \"${model_ref}\"}}
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

chat() {
  local msg="$*"
  if [ -z "$msg" ]; then
    bad "no message. Usage: ./demo/openclaw-sandbox.sh chat \"your message\""
    exit 1
  fi
  ensure_sandbox
  step "Chat with OpenClaw (inside the sandbox)"
  # The credential is an env SecretRef, so the key must be present in the exec
  # environment for the turn. `agent -m` runs one turn via the in-sandbox
  # gateway (which is already running as the sandbox's main process).
  if [ -n "$PROVIDER_API_KEY" ]; then
    openshell sandbox exec -n "$SANDBOX_NAME" --no-tty --timeout 300 \
      --env PROVIDER_API_KEY="$PROVIDER_API_KEY" -- \
      openclaw agent -m "$msg"
  else
    # Key already configured in a prior `configure` run lives in the sandbox
    # state; still inject if the user exported it now.
    openshell sandbox exec -n "$SANDBOX_NAME" --no-tty --timeout 300 -- \
      openclaw agent -m "$msg"
  fi
}

chat_gateway() {
  local msg="$*"
  if [ -z "$msg" ]; then
    bad "no message. Usage: ./demo/openclaw-sandbox.sh chat-gateway \"your message\""
    exit 1
  fi
  ensure_sandbox
  if [ -z "$PROVIDER_API_KEY" ] && [ -z "$NVIDIA_API_KEY" ]; then
    bad "no API key. Set NVIDIA_API_KEY in demo/.env"
    exit 1
  fi

  step "Chat via Agent Gateway egress proxy (SSO → delegation → token → proxy)"

  # 1. Mock SSO sign-in (Dex mock connector)
  local DEX="http://localhost:5556"
  local JAR=$(mktemp)
  local LOC="$DEX/dex/auth?response_type=code&client_id=agent-gateway&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback&connector_id=mock&scope=openid"
  local CODE=""
  for _ in 1 2 3 4 5 6; do
    local NX=$(curl -s -b "$JAR" -c "$JAR" -D - -o /dev/null "$LOC" | grep -i '^location' | head -1 | tr -d '\r' | sed 's/^Location: //' | sed 's|//dex:5556|//localhost:5556|')
    [ -z "$NX" ] && break
    case "$NX" in
      *code=*) CODE=$(echo "$NX" | sed 's/.*code=\([^&]*\).*/\1/'); break;;
      /*) LOC="$DEX$NX" ;;
      *)  LOC="$NX" ;;
    esac
  done
  if [ -z "$CODE" ]; then
    bad "SSO failed to obtain code"
    exit 1
  fi
  local ID_TOKEN
  ID_TOKEN=$(curl -s -X POST "$DEX/dex/token" \
    -d "grant_type=authorization_code&client_id=agent-gateway&code=$CODE&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('id_token',''))" 2>/dev/null || true)
  if [ -z "$ID_TOKEN" ]; then
    bad "failed to exchange code for ID token"
    exit 1
  fi

  # 2. Create delegation for NVIDIA model host with approval rules:
  #    - GET requests auto-allowed
  #    - POST/DELETE/CONNECT require human approval
  step "Creating delegation for integrate.api.nvidia.com (GET auto, POST/DELETE need approval)"
  local DELEGATION
  DELEGATION=$(curl -s -X POST http://localhost:8081/v1/delegations/ \
    -H "Content-Type: application/json" \
    -d "{\"agent_id\":\"openclaw-agent-1\",\"resources\":[\"integrate.api.nvidia.com\"],\"actions\":[\"read\",\"connect\",\"create\",\"delete\"],\"expires_in_seconds\":1800,\"id_token\":\"$ID_TOKEN\",\"approval_rules\":[{\"when\":{\"action_pattern\":\"connect\",\"resource_pattern\":\"*\"},\"require\":true,\"rationale\":\"outbound CONNECT tunnels require approval\"},{\"when\":{\"action_pattern\":\"create\",\"resource_pattern\":\"*\"},\"require\":true,\"rationale\":\"POST/create actions require approval\"},{\"when\":{\"action_pattern\":\"delete\",\"resource_pattern\":\"*\"},\"require\":true,\"rationale\":\"DELETE actions require approval\"}]}")
  local AGENT_TOKEN
  AGENT_TOKEN=$(echo "$DELEGATION" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('token',''))" 2>/dev/null || true)
  if [ -z "$AGENT_TOKEN" ]; then
    bad "failed to mint agent token: $(echo "$DELEGATION" | head -c 200)"
    exit 1
  fi
  okk "delegation created, agent token issued"

  # 3. Build connect-proxy (always cross-compile for linux/amd64)
  local CONNECT_PROXY="/tmp/connect-proxy-linux-amd64"
  if ! have go; then
    bad "go compiler not found — cannot build connect-proxy. Install Go or pre-build /tmp/connect-proxy-linux-amd64"
    exit 1
  fi
  step "Building connect-proxy (linux/amd64)"
  cat > /tmp/connect-proxy.go <<'GOEOF'
package main
import (
  "bufio"
  "fmt"
  "io"
  "log"
  "net"
  "net/url"
  "os"
  "strings"
)
func main() {
  if len(os.Args) < 3 { log.Fatal("usage: connect-proxy <target> <token>") }
  target := os.Args[1]; token := os.Args[2]
  targetURL, _ := url.Parse(target); upstream := targetURL.Host
  listener, err := net.Listen("tcp", ":8888")
  if err != nil { log.Fatal(err) }
  defer listener.Close()
  log.Printf("CONNECT proxy listening on :8888 -> %s", upstream)
  for {
    conn, err := listener.Accept()
    if err != nil { log.Printf("accept error: %v", err); continue }
    go handleConnection(conn, upstream, token)
  }
}
func handleConnection(client net.Conn, upstream, token string) {
  defer client.Close()
  reader := bufio.NewReader(client)
  reqLine, err := reader.ReadString('\n')
  if err != nil { return }
  if !strings.HasPrefix(reqLine, "CONNECT ") { handleHTTP(client, reader, reqLine, upstream, token); return }
  for {
    line, err := reader.ReadString('\n')
    if err != nil || line == "\r\n" || line == "\n" {
      break
    }
  }
  dest := strings.TrimSpace(strings.TrimPrefix(reqLine, "CONNECT ")); dest = strings.Split(dest, " ")[0]
  upstreamConn, err := net.Dial("tcp", upstream)
  if err != nil { log.Printf("dial upstream: %v", err); client.Write([]byte("HTTP/1.1 502 Bad Gateway\r\n\r\n")); return }
  defer upstreamConn.Close()
  connectReq := fmt.Sprintf("CONNECT %s HTTP/1.1\r\nHost: %s\r\n", dest, dest)
  if token != "" { connectReq += fmt.Sprintf("Proxy-Authorization: Bearer %s\r\n", token) }
  connectReq += "\r\n"
  upstreamConn.Write([]byte(connectReq))
  upstreamReader := bufio.NewReader(upstreamConn)
  respLine, _ := upstreamReader.ReadString('\n')
  for {
    line, _ := upstreamReader.ReadString('\n')
    if line == "\r\n" || line == "\n" || line == "" {
      break
    }
  }
  if !strings.Contains(respLine, "200") { client.Write([]byte(respLine)); io.Copy(client, upstreamReader); return }
  client.Write([]byte("HTTP/1.1 200 Connection established\r\n\r\n"))
  go io.Copy(client, upstreamConn); io.Copy(upstreamConn, client)
}
func handleHTTP(client net.Conn, reader *bufio.Reader, reqLine string, upstream, token string) {
  upstreamConn, err := net.Dial("tcp", upstream)
  if err != nil { log.Printf("dial upstream: %v", err); return }
  defer upstreamConn.Close()
  upstreamConn.Write([]byte(reqLine))
  for {
    line, err := reader.ReadString('\n')
    if err != nil || line == "\r\n" || line == "\n" {
      if token != "" && !strings.Contains(reqLine, "Proxy-Authorization") {
        upstreamConn.Write([]byte(fmt.Sprintf("Proxy-Authorization: Bearer %s\r\n", token)))
      }
      upstreamConn.Write([]byte(line))
      break
    }
    upstreamConn.Write([]byte(line))
  }
  io.Copy(upstreamConn, reader)
  io.Copy(client, upstreamConn)
}
GOEOF
    GOOS=linux GOARCH=amd64 go build -o "$CONNECT_PROXY" /tmp/connect-proxy.go

  # 4. Stream connect-proxy into sandbox via stdin (avoids read-only rootfs)
  local SANDBOX_CONTAINER
  # Exclude supervisor containers (they have -supervisor suffix)
  SANDBOX_CONTAINER=$(docker ps --filter "name=openshell-default--${SANDBOX_NAME}" --format '{{.Names}}' | grep -v '\-supervisor$' | head -1)
  if [ -z "$SANDBOX_CONTAINER" ]; then
    bad "cannot find sandbox container for $SANDBOX_NAME"
    exit 1
  fi
  echo "Found sandbox container: $SANDBOX_CONTAINER"
  cat "$CONNECT_PROXY" | docker exec -i "$SANDBOX_CONTAINER" /bin/sh -c "cat > /tmp/connect-proxy && chmod +x /tmp/connect-proxy && /tmp/connect-proxy 'http://172.21.0.1:8088' '$AGENT_TOKEN'" &
  sleep 2

  # 5. Chat with OpenClaw via the proxy
  step "Chat with OpenClaw (via Agent Gateway egress proxy)"
  local api_key="${PROVIDER_API_KEY:-${NVIDIA_API_KEY:-}}"
  openshell sandbox exec -n "$SANDBOX_NAME" --no-tty --timeout 300 \
    --env HTTPS_PROXY=http://127.0.0.1:8888 \
    --env NODE_USE_ENV_PROXY=1 \
    --env NVIDIA_API_KEY="$api_key" \
    -- openclaw agent -m "$msg"
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

case "${1:-}" in
  build)           build ;;
  up)              build; ensure_sandbox; status ;;
  configure)       configure ;;
  chat)            shift; chat "$@" ;;
  chat-gateway)    shift; chat_gateway "$@" ;;
  shell)           shell ;;
  status)          status ;;
  down)            down ;;
  *)
    cat <<EOF
Usage: ./demo/openclaw-sandbox.sh <command>

  build                     Build the OpenClaw image
  up                        Build + launch the sandbox (OpenClaw gateway)
  configure                 Set the model provider + allow egress (needs a key)
  chat "message"            Send one message to the agent
  shell                     Interactive shell inside the sandbox
  status                    Sandbox + gateway status
  down                      Delete the sandbox

Provider (for configure):
  NVIDIA_API_KEY=nvapi-... ./demo/openclaw-sandbox.sh configure
  PROVIDER_BASE_URL=... PROVIDER_API_KEY=... PROVIDER_MODEL=... ./demo/openclaw-sandbox.sh configure
EOF
    ;;
esac

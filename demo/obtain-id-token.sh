#!/usr/bin/env bash
# ============================================================================
# Agent Gateway — obtain an OIDC ID token for a remote tenant
#
# Automates the OIDC authorization-code flow (or Dex password grant) so you
# don't have to copy-paste an `id_token` out of browser DevTools.
#
# Outputs the raw ID token (JWT) on stdout. Pass it as `--id-token` / `ID_TOKEN=`
# to `kill-switch-remote.sh`, or paste it into a delegation body (`"id_token"`).
#
# Two modes:
#
#   1. Authorization-code flow (browser-equivalent, no credentials in this script)
#      You paste the `?code=...` URL you land on after signing in, or the script
#      can follow redirects if your IdP accepts a no-login connector.
#
#   2. Dex password grant (local/dev stacks only — real IdPs usually disable it)
#      Supply --user and --pass and the script gets the token in one curl.
#
# Usage:
#   # Local demo stack (works unattended — Dex mock connector needs no login)
#   ./obtain-id-token.sh
#
#   # Remote tenant — you complete the sign-in in a browser, then paste the code URL
#   ./obtain-id-token.sh \
#     --auth https://idp.preprod.agw.sjfisher.com/dex/auth \
#     --token https://idp.preprod.agw.sjfisher.com/dex/token \
#     --client agent-gateway \
#     --redirect https://console.preprod.agw.sjfisher.com/oidc/callback \
#     --connector mock
#
#   # Dex password grant (dev stacks with password grant enabled)
#   ./obtain-id-token.sh --password --user alice@example.com --pass password
# ============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
  echo "this script must run under BASH" >&2
  echo "Run it as:  bash ./obtain-id-token.sh" >&2
  exit 64
fi

set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

RED=''; GRN=''; YLW=''; BLU=''; BLD=''; RST=''
if [ -t 1 ]; then
  RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[0;33m'; BLU='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
fi
okk()   { printf "  ${GRN}✓ %s${RST}\n" "$*" >&2; }
bad()   { printf "  ${RED}✗ %s${RST}\n" "$*" >&2; }
warn()  { printf "  ${YLW}• %s${RST}\n" "$*" >&2; }
step()  { printf "\n${BLD}${BLU}%s${RST}\n" "$*" >&2; }
line()  { printf "  %s\n" "$*" >&2; }

# --- flags / env -------------------------------------------------------------
AUTH_URL=""
TOKEN_URL=""
CLIENT_ID="agent-gateway"
REDIRECT_URI="http://localhost:8083/oidc/callback"
CONNECTOR_ID="mock"
SCOPE="openid"
USERNAME=""
PASSWORD=""
USE_PASSWORD=0
CODE_URL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --auth)     AUTH_URL="$2"; shift 2 ;;
    --token)    TOKEN_URL="$2"; shift 2 ;;
    --client)   CLIENT_ID="$2"; shift 2 ;;
    --redirect) REDIRECT_URI="$2"; shift 2 ;;
    --connector) CONNECTOR_ID="$2"; shift 2 ;;
    --scope)    SCOPE="$2"; shift 2 ;;
    --user)     USERNAME="$2"; shift 2 ;;
    --pass)     PASSWORD="$2"; shift 2 ;;
    --password) USE_PASSWORD=1; shift ;;
    --code-url) CODE_URL="$2"; shift 2 ;;
    --help|-h)
      echo "usage: $0 [--auth URL] [--token URL] [--client ID] [--redirect URI] [--connector ID] [--scope SCOPE]"
      echo "       $0 --password --user <email> --pass <password>"
      echo "       $0 --code-url 'https://.../oidc/callback?code=...'"
      echo "env:   AUTH_URL TOKEN_URL CLIENT_ID REDIRECT_URI CONNECTOR_ID USERNAME PASSWORD CODE_URL"
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

AUTH_URL="${AUTH_URL:-}"
TOKEN_URL="${TOKEN_URL:-}"
CLIENT_ID="${CLIENT_ID:-agent-gateway}"
REDIRECT_URI="${REDIRECT_URI:-http://localhost:8083/oidc/callback}"
CONNECTOR_ID="${CONNECTOR_ID:-mock}"
SCOPE="${SCOPE:-openid}"
USERNAME="${USERNAME:-}"
PASSWORD="${PASSWORD:-}"
CODE_URL="${CODE_URL:-}"
DEX="${AUTH_URL%/dex/auth}"

ENCODED_REDIRECT=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$REDIRECT_URI")

# --- mode 2: password grant --------------------------------------------------
if [ "$USE_PASSWORD" = "1" ]; then
  if [ -z "$TOKEN_URL" ]; then
    bad "--password requires --token (the IdP token endpoint)"; exit 1
  fi
  if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
    bad "--password requires --user and --pass"; exit 1
  fi
  step "Dex password grant → $TOKEN_URL"
  ID_TOKEN=$(curl -s --max-time 30 -X POST "$TOKEN_URL" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode grant_type=password \
    --data-urlencode client_id="$CLIENT_ID" \
    --data-urlencode username="$USERNAME" \
    --data-urlencode password="$PASSWORD" \
    --data-urlencode scope="$SCOPE" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('id_token',''))" 2>/dev/null || true)
  if [ -n "$ID_TOKEN" ]; then
    okk "ID token obtained (${#ID_TOKEN} chars)"
    printf '%s' "$ID_TOKEN"
    exit 0
  fi
  bad "password grant returned no id_token"
  exit 1
fi

# --- mode 3: user already pasted the code URL --------------------------------
if [ -n "$CODE_URL" ]; then
  if [ -z "$TOKEN_URL" ]; then
    bad "--code-url requires --token (the IdP token endpoint)"; exit 1
  fi
  CODE=$(printf '%s' "$CODE_URL" | sed 's/.*code=\([^&]*\).*/\1/')
  [ "$CODE" = "$CODE_URL" ] && { bad "could not extract a code from that URL"; exit 1; }
  step "Exchanging authorization code → $TOKEN_URL"
  ID_TOKEN=$(curl -s --max-time 30 -X POST "$TOKEN_URL" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode grant_type=authorization_code \
    --data-urlencode client_id="$CLIENT_ID" \
    --data-urlencode code="$CODE" \
    --data-urlencode redirect_uri="$REDIRECT_URI" \
    | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('id_token',''))" 2>/dev/null || true)
  if [ -n "$ID_TOKEN" ]; then
    okk "ID token obtained (${#ID_TOKEN} chars)"
    printf '%s' "$ID_TOKEN"
    exit 0
  fi
  bad "code exchange returned no id_token"
  exit 1
fi

# --- mode 1: full authorization-code flow ------------------------------------
if [ -z "$AUTH_URL" ] || [ -z "$TOKEN_URL" ]; then
  # Local demo stack defaults: try Dex well-known config first
  DEX="http://localhost:5556"
  if curl -sf --max-time 5 "$DEX/dex/.well-known/openid-configuration" >/dev/null 2>&1; then
    warn "no --auth/--token given; using local Dex at $DEX"
    AUTH_URL="$DEX/dex/auth"
    TOKEN_URL="$DEX/dex/token"
  else
    bad "need --auth and --token (or a local Dex at http://localhost:5556)"; exit 1
  fi
fi

fixdex() { sed 's|//dex:5556|//localhost:5556|'; }

step "Step 1 — start OIDC authorization request"
JAR=$(mktemp)
LOC="$AUTH_URL?response_type=code&client_id=$CLIENT_ID&redirect_uri=$ENCODED_REDIRECT&connector_id=$CONNECTOR_ID&scope=$SCOPE"
CODE=""
for _ in 1 2 3 4 5 6; do
  NX=$(curl -s -b "$JAR" -c "$JAR" -D - -o /dev/null "$LOC" \
    | grep -i '^location' | head -1 | tr -d '\r' | sed 's/^Location: //' | fixdex)
  [ -z "$NX" ] && break
  case "$NX" in
    *code=*) CODE=$(echo "$NX" | sed 's/.*code=\([^&]*\).*/\1/'); break ;;
    /*)    LOC="$DEX$NX" ;;
    *)     LOC="$NX" ;;
  esac
done

if [ -z "$CODE" ]; then
  warn "no authorization code returned — your IdP likely requires interactive sign-in"
  line "Complete sign-in in a browser at: $LOC"
  line "Then paste the resulting callback URL (with ?code=...) and re-run:"
  line "  $0 --code-url '<callback-url>' --token $TOKEN_URL --client $CLIENT_ID --redirect $REDIRECT_URI"
  exit 1
fi

step "Step 2 — exchange authorization code for ID token"
ID_TOKEN=$(curl -s --max-time 30 -X POST "$TOKEN_URL" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode grant_type=authorization_code \
  --data-urlencode client_id="$CLIENT_ID" \
  --data-urlencode code="$CODE" \
  --data-urlencode redirect_uri="$REDIRECT_URI" \
  | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('id_token',''))" 2>/dev/null || true)

if [ -n "$ID_TOKEN" ]; then
  okk "ID token obtained (${#ID_TOKEN} chars)"
  printf '%s' "$ID_TOKEN"
  exit 0
fi
bad "code exchange returned no id_token"
exit 1

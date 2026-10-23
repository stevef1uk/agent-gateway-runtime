#!/usr/bin/env bash
set -euo pipefail
GV=http://localhost:8085
AUTHZ=http://localhost:8081
DEX=http://localhost:5556/dex
JAR=$(mktemp); CODE=; DEL_ID=; TOKEN=

step() { echo; echo "== $1"; }

# --- SSO id_token for delegation creation (Dex mock: auto sign-in) ---
sso_id_token() {
  local jar LOC NX codewell="" C
  jar=$(mktemp)
  LOC="$DEX/auth?response_type=code&client_id=agent-gateway&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback&connector_id=mock&scope=openid"
  for _ in 1 2 3 4 5 6; do
    NX=$(curl -s -b "$jar" -c "$jar" -D - -o /dev/null "$LOC" | grep -i '^location' | head -1 | tr -d '\r' | sed 's/^Location: //; s|//dex:5556|//localhost:5556|')
    [ -z "$NX" ] && break
    case "$NX" in
      *code=*) codewell=$(printf '%s' "$NX" | sed 's/.*code=\([^&]*\).*/\1/'); break ;;
      /*) LOC=$(printf '%s' "$NX" | sed 's|//dex:5556|//localhost:5556|' | xargs -0 -I{} echo http://localhost:5556{}) ;;
      *)  LOC="$NX" ;;
    esac
  done
  curl -s -X POST "$DEX/token" \
    -d "grant_type=authorization_code&client_id=agent-gateway&code=$codewell&redirect_uri=http%3A%2F%2Flocalhost%3A8083%2Foidc%2Fcallback" |
    python3 -c 'import sys,json; print(json.load(sys.stdin).get("id_token",""))'
}

step "SSO sign-in (alice via Dex mock)"
ID_TOKEN=$(sso_id_token)
[ -n "$ID_TOKEN" ] || { echo "FAILED: no id_token"; exit 1; }
echo "id_token: ${ID_TOKEN:0:40}…"

step "Create delegation claude-mcp (resources /mcp*) — user_id omitted: the verified OIDC subject is authoritative"
EXISTING=$(curl -s "$AUTHZ/v1/delegations?agent=claude-mcp&status=active" -H "Authorization: Bearer $ID_TOKEN" | \
  python3 -c 'import sys,json; ds=json.load(sys.stdin); print(ds[0]["id"] if ds else "")')
if [ -n "$EXISTING" ]; then
  DEL_ID=$EXISTING
  echo "reusing active delegation: $DEL_ID"
else
  CREATE=$(curl -s -X POST "$AUTHZ/v1/delegations" -H 'Content-Type: application/json' \
    -d "{\"agent_id\":\"claude-mcp\",\"resources\":[\"/mcp*\"],\"actions\":[\"initialize\",\"list\",\"add_customer\",\"lookup_customer\",\"list_customers\"],\"expires_in_seconds\":3600,\"id_token\":\"$ID_TOKEN\"}")
  DEL_ID=$(printf '%s' "$CREATE" | python3 -c 'import sys,json; print(json.load(sys.stdin)["delegation"]["id"])' 2>/dev/null)
  [ -n "$DEL_ID" ] && echo "delegation: $DEL_ID" || { echo "FAILED: $CREATE"; exit 1; }
fi

step "Register connector client (DCR)"
cb=http://127.0.0.1:64820/callback
CID=$(curl -s -X POST "$GV/oauth/register" -H 'Content-Type: application/json' \
  -d "{\"redirect_uris\":[\"$cb\"],\"client_name\":\"Inspector-like local client\"}" |
  python3 -c 'import sys,json; print(json.load(sys.stdin)["client_id"])')
echo "client: $CID"

step "Authorize (PKCE S256)"
STATE=st-$(date +%s)-$RANDOM
VERIF=verifier-$(date +%s)
CHAL=$(printf '%s' "$VERIF" | openssl dgst -sha256 -binary | basenc --base64url | tr -d '=')
LOC=$(curl -s -b "$JAR" -c "$JAR" -D - -o /dev/null "$GV/oauth/authorize?response_type=code&client_id=$CID&redirect_uri=$(python3 -c "import urllib.parse;print(urllib.parse.quote('$cb',safe=''))")&state=$STATE&code_challenge=$CHAL&code_challenge_method=S256" | grep -i '^location' | head -1 | tr -d '\r' | sed 's/^Location: //')
echo "IdP redirect: ${LOC:0:80}…"

step "Follow sign-in through Dex back to the gateway callback"
NX="$LOC"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  case "$NX" in /*) NX="http://localhost:8085${NX}" ;; esac
  NX=$(curl -s -b "$JAR" -c "$JAR" -D - -o /dev/null "$NX" | grep -i '^location' | head -1 | tr -d '\r' | sed 's/^Location: //; s|//dex:5556|//localhost:5556|')
  [ -z "$NX" ] && break
  case "$NX" in $cb*) echo "BACK AT CLIENT CALLBACK: ${NX:0:90}…"; break ;; esac
  echo "  → ${NX:0:80}"
done
CODE=$(printf '%s' "$NX" | sed 's/.*[?&]code=\([^&]*\).*/\1/')
[ -n "$CODE" ] || { echo "FAILED: no code"; exit 1; }

step "Exchange code + PKCE verifier for tokens"
RESP=$(curl -s -X POST "$GV/oauth/token" \
  -d grant_type=authorization_code -d code=$CODE -d client_id=$CID \
  -d redirect_uri=$cb -d code_verifier=$VERIF)
TOKEN=$(printf '%s' "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
REFRESH=$(printf '%s' "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("refresh_token",""))' 2>/dev/null)
[ -n "$TOKEN" ] && echo "access_token granted (+refresh: $([ -n "$REFRESH" ] && echo yes))" || { echo "FAILED: $RESP"; exit 1; }

step "MCP tools/list with the connector token"
curl -s -X POST "$GV/mcp" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | head -c 200; echo

step "MCP tools/call add_customer"
curl -s -X POST "$GV/mcp" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"add_customer","arguments":{"first_name":"One","last_name":"Ring","email":"one.ring@example.com"}}}' | head -c 200; echo

step "Out-of-band proof + audit"
curl -s http://localhost:8091/customers | python3 -c 'import sys,json; d=json.load(sys.stdin); print("CRM customers:", len(d["customers"]))'
docker exec agent-gateway-postgres psql -U agentgw -d agent_gateway -t \
  -c "SELECT ts, agent_id, resource, action, outcome FROM audit_events WHERE resource LIKE '/mcp%' ORDER BY ts DESC LIMIT 3;"

echo; echo "== Save IDs"; printf "DEL_ID=%s\nTOKEN=%s\nREFRESH=%s\n" "$DEL_ID" "$TOKEN" "$REFRESH" > /tmp/opencode/flow_ids.env

#!/bin/bash
# Smoke test for the agentgw k3s deployment (run from this box).
NODE=${1:-192.168.1.74}
WEB=http://$NODE:30083
GW=http://$NODE:30080
TS=http://$NODE:30082
AUTHZ=http://$NODE:30081
CALLBACK=http://$NODE:30083/oidc/callback

JAR=$(mktemp)
LOC="$WEB/oidc/idp/dex/auth?response_type=code&client_id=agent-gateway&redirect_uri=http%3A%2F%2F$NODE%3A30083%2Foidc%2Fcallback&connector_id=mock&scope=openid"
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
echo "auth code: [$CODE]"
ID_TOKEN=$(curl -s -b "$JAR" -c "$JAR" -X POST "$WEB/oidc/idp/dex/token" \
  -d "grant_type=authorization_code&client_id=agent-gateway&code=$CODE&redirect_uri=http%3A%2F%2F$NODE%3A30083%2Foidc%2Fcallback" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id_token','EXCHANGE-FAILED:'+str(d)))")
SUBJECT=$(printf '%s' "$ID_TOKEN" | cut -d. -f2 | python3 -c "import sys,json,base64; t=sys.stdin.read().strip(); t+='='*(-len(t)%4); print(json.loads(base64.urlsafe_b64decode(t)).get('sub','') if '.' not in t else '')")
echo "SSO subject: [$SUBJECT]"
[ -z "$SUBJECT" ] && { echo "ABORT: no ID token"; exit 1; }

D=$(curl -s -X POST "$AUTHZ/v1/delegations/" -H 'Content-Type: application/json' \
  -d "{\"id_token\":\"$ID_TOKEN\",\"agent_id\":\"purchasing-agent-42\",\"resources\":[\"/orders\"],\"actions\":[\"read\",\"create\"],\"expires_in_seconds\":1800,\"limits\":{\"spend_per_order\":{\"type\":\"currency\",\"max\":200,\"unit\":\"EUR\"}}}")
DELEG=$(echo "$D" | python3 -c 'import sys,json; print(json.load(sys.stdin)["delegation"]["id"])' 2>/dev/null)
SECRET=$(echo "$D" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("agent_secret","") or json.load(sys.stdin).get("agent_secret"))' 2>/dev/null || echo "$D" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("agent_secret",""))')
echo "delegation: [$DELEG] secret: [${SECRET:0:8}…]"

TOK=$(curl -s -X POST "$TS/token" -H 'Content-Type: application/json' \
  -d "{\"delegation_id\":\"$DELEG\",\"ttl_seconds\":300,\"agent_secret\":\"$SECRET\"}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("access_token",""))')
[ -z "$TOK" ] && { echo "ABORT: mint failed"; exit 1; }
echo "minted: ${TOK:0:18}…"

C1=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/orders" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"amount":150,"supplier":"acme"}')
echo "EUR150 -> $C1 (want 200)"
APR=$(curl -s -X POST "$GW/orders" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"amount":250,"supplier":"acme"}' | python3 -c 'import sys,json; print(json.load(sys.stdin).get("approval_id",""))')
echo "EUR250 held -> approval [$APR] (want 202 shape)"
DEC=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/v1/approvals/" -H 'Content-Type: application/json' \
  -H "X-Admin-Token: agent-gateway-demo-admin" -d "{\"approval_id\":\"$APR\",\"approver_id\":\"$SUBJECT\",\"approved\":true}")
echo "approve as bound subject -> $DEC (want 200)"
BAD=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/v1/approvals/" -H 'Content-Type: application/json' \
  -H "X-Admin-Token: agent-gateway-demo-admin" -d "{\"approval_id\":\"$APR\",\"approver_id\":\"mallory\",\"approved\":true}")
echo "replay/mallory approve -> $BAD (want 409/403/404, never 200)"
C3=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/orders" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"amount":250,"supplier":"acme"}')
echo "post-approval retry -> $C3 (want 200)"
curl -s -o /dev/null -X DELETE "$AUTHZ/v1/delegations/$DELEG" -H "Authorization: Bearer $ID_TOKEN"
C4=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$GW/orders" -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"amount":150,"supplier":"acme"}')
echo "after revoke -> $C4 (want 403)"

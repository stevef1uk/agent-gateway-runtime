#!/usr/bin/env bash
# ============================================================================
# create-claude-delegation.sh — provision the delegation the Claude.ai remote
# connector needs on a k3s deployment (the script this project's k3s install
# uses — see k3s/agentgw.yaml + docs/Claude-Integration.md).
#
# WHY THIS SCRIPT EXISTS (three traps the admin console form cannot avoid):
#   1. The connector's handshake needs the DISCOVERY actions "initialize" and
#      "list" in the delegation, not just tool names. The console form only
#      offers tool names — without these two, EVERY call (initialize,
#      server/discover) is denied and Claude reports "Couldn't connect".
#   2. The console form hardcodes expires_in_seconds=1800 (30 minutes). The
#      delegation expires between attempts and Claude reports
#      "No active delegation exists for your account."
#   3. A delegation is bound to the VERIFIED SUBJECT of the ID token used at
#      creation. Dex's password grant (local connector) and the browser's
#      mock connector produce DIFFERENT subjects for the same human, so a
#      delegation minted via the password grant is invisible to the console
#      session and to the connector's sign-in. This script rebinds the
#      delegation to the subject the OAuth sign-in actually uses.
#
# WHAT IT DOES (idempotent):
#   0. optionally REVOKES previous delegations for the agent (--replace;
#      auto-bind requires exactly ONE active delegation)
#   1. kubectl port-forwards dex + authz
#   2. mints a verified ID token (Dex password grant)
#   3. POSTs the delegation: discovery actions + your TOOL_ACTIONS +
#      an approval rule on DELETE_PATTERN (held 202 until a human approves)
#   4. rebinds the delegation's user_id to the OAUTH_SUBJECT whose
#      connector-based sign-in the console/claude.ai actually uses
#   5. verifies the row in Postgres
#
# USAGE (namespace agentgw, default demo subject):
#   ./create-claude-delegation.sh
#   ./create-claude-delegation.sh --replace          # revoke previous first
#   SUBJECT=$(your-oidc-subject) AGENT_ID=my-agent ./create-claude-delegation.sh
#
# After it prints "DONE": in claude.ai just click Connect — exactly one active
# delegation exists, so the gateway auto-binds it (no console visit needed).
# ============================================================================
set -euo pipefail

NS=${NAMESPACE:-agentgw}
PG_POD=${PG_POD:-$(kubectl -n "$NS" get pods -l app=postgres -o jsonpath='{.items[0].metadata.name}')}
AUTHZ_PORT=${AUTHZ_PORT:-18081}
DEX_PORT=${DEX_PORT:-15556}
OIDC_USER=${OIDC_USER:-alice}
OIDC_PASSWORD=${OIDC_PASSWORD:-password}
# The verified subject your BROWSER sign-in produces. For the demo Dex mock
# connector this is the fixed fixture subject below; with a real IdP pass the
# real subject (check an audit row: SELECT DISTINCT user_id FROM audit_events).
OAUTH_SUBJECT=${OAUTH_SUBJECT:-Cg0wLTM4NS0yODA4OS0wEgRtb2Nr}
AGENT_ID=${AGENT_ID:-claude-mcp}
TTL=${TTL:-43200}   # 12h; a delegation the connector binds to must outlive testing sessions
RESOURCE=${RESOURCE:-/mcp*}
TOOL_ACTIONS=${TOOL_ACTIONS:-"add_customer lookup_customer list_customers find_customer delete_customer"}
DELETE_PATTERN=${DELETE_PATTERN:-delete_customer}   # tail of $TOOL_ACTIONS that must require human approval; "" disables the rule
REPLACE=${1:-}

say()   { printf "\033[1;36m==> %s\033[0m\n" "$*"; }
ok()    { printf "    \033[0;32m✓ %s\033[0m\n" "$*"; }
die()   { printf "    \033[0;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }
have()  { command -v "$1" >/dev/null; }

have kubectl || die "kubectl required"
have curl    || die "curl required"
have jq      || die "jq required"

PF_PID=()
cleanup() { for p in "${PF_PID[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT

pf() { # pf <pod|svc/name> <lport> <rport>
  kubectl -n "$NS" port-forward "$1" "$2:$3" >/dev/null 2>&1 &
  PF_PID+=("$!")
}

# 0 — optional: clear previous delegations for this agent (one active ONLY)
if [ "$REPLACE" = "--replace" ]; then
  say "revoking previous delegations for agent '$AGENT_ID'"
  for d in $(kubectl -n "$NS" exec "$PG_POD" -- psql -U agentgw -d agent_gateway -tA -c \
    "SELECT id FROM delegations WHERE agent_id='$AGENT_ID' AND revoked_at IS NULL;"); do
    kubectl -n "$NS" exec "$PG_POD" -- psql -U agentgw -d agent_gateway -c \
      "UPDATE delegations SET revoked_at=now() WHERE id='$d';" >/dev/null
    ok "revoked $d"
  done
fi

# 1 — reach the services
say "port-forwarding dex:$DEX_PORT authz:$AUTHZ_PORT"
pf svc/dex "$DEX_PORT" 5556
pf svc/authz "$AUTHZ_PORT" 8081
sleep 2
curl -fsS "http://localhost:$DEX_PORT/dex/.well-known/openid-configuration" >/dev/null || die "dex not reachable"

# 2 — mint a verified ID token (password grant)
say "minting ID token for '$OIDC_USER' via Dex password grant"
ID_TOKEN=$(curl -fsS -X POST "http://localhost:$DEX_PORT/dex/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode grant_type=password \
  --data-urlencode client_id=agent-gateway \
  --data-urlencode username="${OIDC_USER}@example.com" \
  --data-urlencode password="$OIDC_PASSWORD" \
  --data-urlencode scope="openid email profile" | jq -r .id_token)
[ -n "$ID_TOKEN" ] && [ "$ID_TOKEN" != "null" ] || die "no id_token from Dex"

# 3 — create the delegation (discovery + tools + approval rule)
ACTIONS='["initialize","list"'
for a in $TOOL_ACTIONS; do ACTIONS="$ACTIONS,\"$a\""; done
ACTIONS="$ACTIONS]"
RULE=""
if [ -n "$DELETE_PATTERN" ]; then
  RULE=",\"approval_rules\":[{\"when\":{\"resource_pattern\":\"$RESOURCE\",\"action_pattern\":\"$DELETE_PATTERN\"},\"require\":true,\"rationale\":\"Deleting customer data: verify this is the right record before approving\"}]"
fi
say "creating delegation agent=$AGENT_ID resource=$RESOURCE ttl=${TTL}s"
RESP=$(curl -fsS -X POST "http://localhost:$AUTHZ_PORT/v1/delegations/" \
  -H 'Content-Type: application/json' \
  -d "{\"id_token\":\"$ID_TOKEN\",\"agent_id\":\"$AGENT_ID\",\"resources\":[\"$RESOURCE\"],\"actions\":$ACTIONS,\"expires_in_seconds\":$TTL$RULE}")
DELEG_ID=$(echo "$RESP" | jq -r '.delegation.id // .id')
[ -n "$DELEG_ID" ] || die "delegation creation failed: $RESP"
ok "created $DELEG_ID"

# 4 — rebind to the subject the OAuth sign-in uses (trap 3)
if [ "$(echo "$RESP" | jq -r '.delegation.user_id // .user_id')" != "$OAUTH_SUBJECT" ]; then
  say "rebinding user_id -> $OAUTH_SUBJECT (connector sign-in subject)"
  kubectl -n "$NS" exec "$PG_POD" -- psql -U agentgw -d agent_gateway -c \
    "UPDATE delegations SET user_id='$OAUTH_SUBJECT', data=jsonb_set(data,'{user_id}',to_jsonb('$OAUTH_SUBJECT'::text)) WHERE id='$DELEG_ID';" >/dev/null
  ok "rebound"
fi

# 5 — verify in Postgres
say "verify"
kubectl -n "$NS" exec "$PG_POD" -- psql -U agentgw -d agent_gateway -c \
  "SELECT id, user_id, agent_id, data->>'actions' AS actions, expires_at FROM delegations WHERE id='$DELEG_ID';"

cat <<EOF
DONE. In claude.ai:
  Settings → Connectors → Add custom connector
  URL:  https://<your-gateway-host>/mcp     (Register automatically)
  Click Connect → the ONE active delegation auto-binds.
  "add a customer" executes; "delete that customer" is HELD (202) until a
  human approves (Telegram card / console). Every call audited.
EOF

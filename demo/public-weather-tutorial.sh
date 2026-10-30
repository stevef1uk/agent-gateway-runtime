#!/usr/bin/env bash
# Protect Open-Meteo using only curl for HTTP and jq for JSON.
# Setup and individual commands: ../docs/Public-API-Curl-Tutorial.md
set -euo pipefail

YES=0
case "${1:-}" in
  --yes) YES=1; shift ;;
  --help|-h)
    printf 'Usage: bash %s [--yes]\n' "$0"
    printf 'Default: pause before the operator approval. --yes: scripted approval.\n'
    printf 'Environment: GW AUTHZ TS DEX ADMIN_TOKEN WEATHER_HOST_PORT\n'
    exit 0 ;;
esac
if [ "$#" -ne 0 ]; then
  printf 'Unknown argument: %s\n' "$1" >&2
  exit 2
fi
for tool in curl jq mktemp; do
  command -v "$tool" >/dev/null || { printf 'Required command missing: %s\n' "$tool" >&2; exit 1; }
done

GW=${GW:-http://localhost:${WEATHER_HOST_PORT:-8087}}
AUTHZ=${AUTHZ:-http://localhost:8081}
TS=${TS:-http://localhost:8082}
DEX=${DEX:-http://localhost:5556}
ADMIN_TOKEN=${ADMIN_TOKEN:-agent-gateway-demo-admin}
QUERY='latitude=51.5072&longitude=-0.1276'
FORECAST="$GW/v1/forecast?$QUERY&current=temperature_2m,wind_speed_10m&forecast_days=1"
ELEVATION="$GW/v1/elevation?$QUERY"
ID_TOKEN=''
DELEGATION_ID=''
REVOKED=0
umask 077
RESPONSE=$(mktemp)

cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$DELEGATION_ID" ] && [ "$REVOKED" = 0 ]; then
    if ! curl --fail --silent --show-error --connect-timeout 5 --max-time 15 \
      -X DELETE "$AUTHZ/v1/delegations/$DELEGATION_ID" \
      -H "Authorization: Bearer $ID_TOKEN" >/dev/null; then
      printf 'Cleanup could not revoke delegation %s; revoke it manually (or wait for its 30-minute expiry).\n' "$DELEGATION_ID" >&2
    fi
  fi
  rm -f "$RESPONSE"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

step() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAILED: %s\n' "$*" >&2; exit 1; }
# Expected denials are assertions, not curl failures. Transport errors still fail.
request() {
  local expected=$1
  shift
  HTTP=$(curl --silent --show-error --connect-timeout 5 --max-time 30 \
    -o "$RESPONSE" -w '%{http_code}' "$@") || fail 'curl transport error'
  case " $expected " in
    *" $HTTP "*) printf '   HTTP %s (expected)\n' "$HTTP" ;;
    *)
      printf '   Expected HTTP %s; received HTTP %s.\n' "$expected" "$HTTP" >&2
      # Print only error fields: credential responses are never dumped.
      jq -c '{error, reason, message}' "$RESPONSE" >&2 2>/dev/null || true
      fail 'unexpected HTTP status; see the tutorial troubleshooting section' ;;
  esac
}

step '1. Check the running services'
for endpoint in "$GW/healthz" "$AUTHZ/healthz" "$TS/healthz" "$DEX/dex/.well-known/openid-configuration"; do
  request 200 "$endpoint"
done

step '2. Sign in as Alice using the local Dex demo password grant'
request 200 "$DEX/dex/token" \
  --data-urlencode grant_type=password \
  --data-urlencode client_id=agent-gateway \
  --data-urlencode scope=openid \
  --data-urlencode username=alice@example.com \
  --data-urlencode password=password
ID_TOKEN=$(jq -er '.id_token | strings | select(length > 0)' "$RESPONSE")

step '3. Delegate weather reads; elevation requires approval'
PAYLOAD=$(jq -n --arg id_token "$ID_TOKEN" '{
  id_token: $id_token, agent_id: "weather-tutorial-agent",
  resources: ["/v1/forecast", "/v1/elevation"], actions: ["read"],
  expires_in_seconds: 1800, max_depth: 0,
  approval_rules: [{when: {resource_pattern: "/v1/elevation", action_pattern: "read"},
    require: true, rationale: "Elevation lookups need a human decision in this tutorial"}]
}')
request '200 201' "$AUTHZ/v1/delegations/" \
  -H 'Content-Type: application/json' -d "$PAYLOAD"
DELEGATION_ID=$(jq -er '.delegation.id | strings | select(length > 0)' "$RESPONSE")
AGENT_SECRET=$(jq -er '.agent_secret | strings | select(length > 0)' "$RESPONSE")
SUBJECT=$(jq -er '.delegation.user_id | strings | select(length > 0)' "$RESPONSE")
printf '   Delegation: %s\n   Verified delegating subject: %s\n' "$DELEGATION_ID" "$SUBJECT"

step '4. Agent exchanges its delegation ID and secret for a five-minute token'
PAYLOAD=$(jq -n --arg id "$DELEGATION_ID" --arg secret "$AGENT_SECRET" \
  '{delegation_id: $id, agent_secret: $secret, ttl_seconds: 300}')
request 200 "$TS/token" -H 'Content-Type: application/json' -d "$PAYLOAD"
AGENT_TOKEN=$(jq -er '.access_token | strings | select(length > 0)' "$RESPONSE")
unset AGENT_SECRET PAYLOAD

step '5. No token: the forecast is refused'
request 401 "$FORECAST"

step '6. Authorized forecast: get real London weather'
request 200 "$FORECAST" -H "Authorization: Bearer $AGENT_TOKEN"
jq -e '.current.temperature_2m != null and .current.wind_speed_10m != null' "$RESPONSE" >/dev/null \
  || fail 'expected an Open-Meteo forecast, not a synthetic gateway response'
jq '{latitude, longitude, current_units, current}' "$RESPONSE"

step '7. Read-only scope: a POST is refused'
request 403 -X POST "$FORECAST" -H "Authorization: Bearer $AGENT_TOKEN"

step '8. Resource scope: an undelegated path is refused'
request 403 "$GW/v1/marine?$QUERY" -H "Authorization: Bearer $AGENT_TOKEN"

step '9. Elevation lookup: held for approval'
request 202 "$ELEVATION" -H "Authorization: Bearer $AGENT_TOKEN"
APPROVAL_ID=$(jq -er '.approval_id | strings | select(length > 0)' "$RESPONSE")
printf '   Approval: %s\n' "$APPROVAL_ID"

step '10. Operator records the delegating human’s approval'
printf '   This step uses the operator credential, never the agent token.\n'
if [ "$YES" = 0 ]; then
  [ -t 0 ] || fail 'interactive approval needs a terminal; use --yes for a scripted run'
  read -r -p 'Press Enter to approve this elevation lookup as Alice (Ctrl-C cancels): ' _
else
  printf '   --yes: recording a scripted demo approval as Alice.\n'
fi
PAYLOAD=$(jq -n --arg id "$APPROVAL_ID" --arg subject "$SUBJECT" \
  '{approval_id: $id, approver_id: $subject, approved: true}')
request 200 "$GW/v1/approvals/" -H "X-Admin-Token: $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' -d "$PAYLOAD"

step '11. Retry the identical lookup: the real elevation is returned'
request 200 "$ELEVATION" -H "Authorization: Bearer $AGENT_TOKEN"
jq -e '.elevation | type == "array" and length > 0' "$RESPONSE" >/dev/null \
  || fail 'expected an Open-Meteo elevation response'
jq . "$RESPONSE"

step '12. Approval is single-use: another lookup is held again'
request 202 "$ELEVATION" -H "Authorization: Bearer $AGENT_TOKEN"
jq -e --arg old "$APPROVAL_ID" '.approval_id != null and .approval_id != $old' "$RESPONSE" >/dev/null \
  || fail 'expected a fresh approval ID'

step '13. Revoke the delegation, then reuse the same agent token'
request '200 204' -X DELETE "$AUTHZ/v1/delegations/$DELEGATION_ID" \
  -H "Authorization: Bearer $ID_TOKEN"
REVOKED=1
request 403 "$FORECAST" -H "Authorization: Bearer $AGENT_TOKEN"

step '14. Read the audit trail for this delegation'
request 200 "$GW/v1/audit/?delegation_id=$DELEGATION_ID&limit=100" \
  -H "X-Admin-Token: $ADMIN_TOKEN"
jq -e --arg id "$DELEGATION_ID" --arg approval "$APPROVAL_ID" '
  .events | length > 0 and all(.[]; .delegation_id == $id)
  and any(.[]; .outcome == "allow" and .resource == "/v1/forecast")
  and any(.[]; .outcome == "allow" and .approval_id == $approval)
  and any(.[]; .outcome == "approval_required")
  and any(.[]; .outcome == "deny")
' "$RESPONSE" >/dev/null || fail 'expected allow, approved execution, hold and deny audit evidence'
jq '.events[] | {ts, agent_id, user_id, resource, action, outcome, status_code, approval_id, approver_id, reason}' "$RESPONSE"

printf '\nPASS: real forecast, read/path denials, approval, single-use consent, revocation and audit.\n'

#!/usr/bin/env bash
# AWS public-client probes only. Human decisions happen in the signed-in console.
set -euo pipefail
phase="${1:-access}"
case "$phase" in access|approved|revoked) ;; -h|--help)
 echo 'Usage: GATEWAY_URL=https://ID.execute-api.REGION.amazonaws.com bash demo/public-weather-tutorial.sh [access|approved|revoked]'
 echo 'AGENT_TOKEN is read privately if absent. This script never approves or revokes.'
 exit 0;; *) echo 'Unknown phase: use access, approved or revoked.' >&2;exit 2;; esac
[[ $# -le 1 ]] || { echo 'Too many arguments.' >&2;exit 2; }
for tool in curl python3; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2;exit 1; };done
gateway="${GATEWAY_URL:-}"
# The current deployment uses root execute-api URLs. Do not send agent tokens to
# the public weather provider, localhost, an HTTP URL or an unreviewed redirect.
[[ "$gateway" =~ ^https://[a-z0-9]+\.execute-api\.[a-z0-9-]+\.amazonaws\.com/?$ ]] || { echo 'Set GATEWAY_URL to your public AWS GatewayURL output (HTTPS, no path).' >&2;exit 2; }
gateway="${gateway%/}"
token="${AGENT_TOKEN:-}"
if [[ -z "$token" ]];then read -r -s -p 'Agent token: ' token;printf '\n';fi
[[ -n "$token" ]] || { echo 'Agent token is required.' >&2;exit 2; }
work="$(mktemp -d)";trap 'rm -rf "$work"' EXIT
query='latitude=51.5072&longitude=-0.1276'
forecast="/v1/forecast?$query&current=temperature_2m,wind_speed_10m&forecast_days=1"
elevation="/v1/elevation?$query"
probe(){
 local label="$1" expected="$2" method="$3" path="$4" authenticated="$5"
 shift 5
 local status
 local curl_args=(--silent --show-error --max-time 20 --output "$work/response.json" --write-out '%{http_code}' -X "$method")
 if [[ "$authenticated" == yes ]];then curl_args+=(-H "Authorization: Bearer $token");fi
 status="$(curl -q "${curl_args[@]}" "$@" "$gateway$path")"
 [[ "$status" == "$expected" ]] || { echo "FAIL $label: expected $expected, got $status. Check token expiry, deployment and provider availability." >&2;exit 1; }
 python3 - "$work/response.json" "$expected" "$label" <<'PY'
import json,sys
path,status,label=sys.argv[1:]
if status in ['200','202']:
 data=json.load(open(path))
 if status=='202':
  assert data.get('approval_id'), 'Missing approval_id'
  print('Approval ID:',data['approval_id'])
 elif label=='forecast':
  assert 'temperature_2m' in data.get('current',{}) and 'wind_speed_10m' in data.get('current',{}), 'Missing real weather fields'
 elif label=='approved-elevation':
  assert isinstance(data.get('elevation'),list) and data['elevation'], 'Missing elevation array'
PY
 printf 'PASS %s: HTTP %s\n' "$label" "$status"
}
printf 'Weather data by Open-Meteo.com — https://open-meteo.com/\n'
case "$phase" in
 access)
  probe no-token 401 GET "$forecast" no
  probe forecast 200 GET "$forecast" yes
  probe forbidden-method 403 POST "$forecast" yes
  probe forbidden-path 403 GET "/v1/marine?$query" yes
  probe mapping-override-refused 403 POST "$forecast" yes -H 'X-Agent-Action: read'
  probe elevation-held 202 GET "$elevation" yes
  echo 'Approve that elevation request in your signed-in console, then run the approved phase.';;
 approved)
  probe approved-elevation 200 GET "$elevation" yes
  probe approval-consumed 202 GET "$elevation" yes
  echo 'Revoke the delegation in your console, then run the revoked phase before token expiry.';;
 revoked)
  probe revoked-token 403 GET "$forecast" yes
  echo 'Revocation checked. Review the audit trail and clean up the disposable AWS stack if finished.';;
esac

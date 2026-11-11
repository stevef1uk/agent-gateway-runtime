#!/usr/bin/env bash
# GCP public-client probes through the Console's same-origin Gateway proxy.
set -euo pipefail

phase="${1:-access}"
case "$phase" in
  access|approved|revoked) ;;
  -h|--help)
    echo 'Usage: CONSOLE_URL=https://WEB-SERVICE-HASH.REGION.run.app bash demo/public-weather-tutorial-gcp.sh [access|approved|revoked]'
    echo 'AGENT_TOKEN is read privately if absent. This script never approves or revokes.'
    exit 0
    ;;
  *)
    echo 'Unknown phase: use access, approved or revoked.' >&2
    exit 2
    ;;
esac
[[ $# -le 1 ]] || { echo 'Too many arguments.' >&2; exit 2; }

for tool in curl python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing $tool" >&2; exit 1; }
done

console="${CONSOLE_URL:-}"
[[ "$console" =~ ^https://[a-z0-9-]+-[0-9]+\.[a-z0-9-]+\.run\.app/?$ ]] || {
  echo 'Set CONSOLE_URL to the public GCP Console Cloud Run URL (HTTPS, no path), not the private Gateway URL.' >&2
  exit 2
}
console="${console%/}"
token="${AGENT_TOKEN:-}"
if [[ -z "$token" ]]; then
  read -r -s -p 'Agent access token: ' token
  printf '\n'
fi
[[ -n "$token" ]] || { echo 'Agent token is required.' >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
query='latitude=51.5072&longitude=-0.1276'
forecast="/v1/forecast?$query&current=temperature_2m,wind_speed_10m&forecast_days=1"
elevation="/v1/elevation?$query"

probe() {
  local label="$1" expected="$2" method="$3" path="$4" authenticated="$5"
  shift 5
  local status
  local curl_args=(--silent --show-error --max-time 25 --output "$work/response.json" --write-out '%{http_code}' -X "$method")
  if [[ "$authenticated" == yes ]]; then
    curl_args+=(-H "Authorization: Bearer $token")
  fi
  status="$(curl -q "${curl_args[@]}" "$@" "$console$path")"
  [[ "$status" == "$expected" ]] || {
    echo "FAIL $label: expected $expected, got $status. Check token expiry, deployment and provider availability." >&2
    exit 1
  }
  python3 - "$work/response.json" "$expected" "$label" <<'PY'
import json
import sys

path, status, label = sys.argv[1:]
if status in {"200", "202"}:
    with open(path, encoding="utf-8") as response:
        data = json.load(response)
    if status == "202":
        assert data.get("approval_id"), "Missing approval_id"
        print("Approval ID:", data["approval_id"])
    elif label == "forecast":
        current = data.get("current", {})
        assert "temperature_2m" in current and "wind_speed_10m" in current, "Missing weather fields"
    elif label == "approved-elevation":
        assert isinstance(data.get("elevation"), list) and data["elevation"], "Missing elevation array"
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
    echo 'Approve that elevation request in the signed-in GCP Console, then run the approved phase.'
    ;;
  approved)
    probe approved-elevation 200 GET "$elevation" yes
    probe approval-consumed 202 GET "$elevation" yes
    echo 'Revoke the delegation in the Console, then run the revoked phase before token expiry.'
    ;;
  revoked)
    probe revoked-token 403 GET "$forecast" yes
    echo 'Revocation checked. Review the audit trail and remove the disposable GCP deployment when finished.'
    ;;
esac

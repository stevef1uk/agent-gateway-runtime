#!/usr/bin/env bash

local_demo_id_token() {
  local token_url="${1:-http://localhost:5556/dex/token}"
  local username="${DEMO_LOGIN_EMAIL:-alice@example.com}"
  local password="${DEMO_LOGIN_PASSWORD:-password}"
  local response

  response=$(curl --fail --silent --show-error --connect-timeout 5 --max-time 20 \
    "$token_url" \
    --data-urlencode grant_type=password \
    --data-urlencode client_id=agent-gateway \
    --data-urlencode scope=openid \
    --data-urlencode "username=$username" \
    --data-urlencode "password=$password") || return 1

  printf '%s' "$response" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("id_token", ""))'
}

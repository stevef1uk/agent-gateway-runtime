#!/usr/bin/env bash

load_admin_token() {
  if [ -n "${ADMIN_TOKEN:-}" ]; then
    return 0
  fi
  if [ -n "${GATEWAY_ADMIN_TOKEN:-}" ]; then
    ADMIN_TOKEN="$GATEWAY_ADMIN_TOKEN"
  else
    local demo_dir env_file
    demo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    env_file="$demo_dir/.env"
    if [ -f "$env_file" ]; then
      ADMIN_TOKEN="$(awk -F= '$1 == "GATEWAY_ADMIN_TOKEN" { sub(/^[^=]*=/, ""); print; exit }' "$env_file")"
    fi
  fi
  if [ -z "${ADMIN_TOKEN:-}" ]; then
    echo "gateway admin token missing; run demo/ensure-secrets.sh or set ADMIN_TOKEN" >&2
    return 1
  fi
}

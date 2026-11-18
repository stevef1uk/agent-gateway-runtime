#!/usr/bin/env bash
set -euo pipefail

demo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$demo_dir"

command -v openssl >/dev/null || {
  echo "openssl is required to generate local demo secrets" >&2
  exit 1
}

if [ ! -f .env ]; then
  cp .env.example .env
fi
chmod 600 .env

read_env_value() {
  awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' .env
}

ensure_secret() {
  local name="$1" value invalid=0
  value="$(read_env_value "$name")"
  if [ -z "$value" ]; then
    value="$(openssl rand -hex 32)"
    if grep -q "^${name}=" .env; then
      tmp_file="$(mktemp "${demo_dir}/.env.XXXXXX")"
      awk -v key="$name" -v replacement="$value" '
        index($0, key "=") == 1 { print key "=" replacement; found=1; next }
        { print }
        END { if (!found) print key "=" replacement }
      ' .env > "$tmp_file"
      chmod 600 "$tmp_file"
      mv "$tmp_file" .env
    else
      printf '%s=%s\n' "$name" "$value" >> .env
    fi
    return
  fi
  case "$value" in
    dev-secret-change-in-prod|agent-gateway-dev-secret-change-in-prod|\
    agent-gateway-demo-secret-change-in-prod|local-dev-secret|\
    agent-gateway-demo-admin|demo-admin-token) invalid=1 ;;
  esac
  if [ "${#value}" -lt 32 ] || [ "$invalid" -eq 1 ]; then
    echo "$name in demo/.env must be replaced with at least 32 random bytes; value was not changed" >&2
    return 1
  fi
}

for name in JWT_SECRET GATEWAY_ADMIN_TOKEN; do
  ensure_secret "$name"
done

jwt_secret="$(read_env_value JWT_SECRET)"
admin_token="$(read_env_value GATEWAY_ADMIN_TOKEN)"
if [ "$jwt_secret" = "$admin_token" ]; then
  echo "JWT_SECRET and GATEWAY_ADMIN_TOKEN in demo/.env must be independent" >&2
  exit 1
fi

echo "Local demo JWT and admin secrets are configured in demo/.env."

#!/usr/bin/env bash
# Automated Playwright + CLI runner for the AWS Open-Meteo Weather Demo.
# Drives the live Console UI via Playwright (no DevTools copy-pasting required)
# and executes the access, approved, and revoked probe phases via
# demo/public-weather-tutorial.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
RUNTIME_ROOT="$(pwd)"

DEFAULT_ENV_FILE="${AGW_OUTPUTS_FILE:-$RUNTIME_ROOT/../agent-gateway/dist/aws-lambda/plan/deployment-outputs.env}"
if [[ -f "$DEFAULT_ENV_FILE" && -z "${CONSOLE_URL:-}" && -z "${GATEWAY_URL:-}" ]]; then
  # shellcheck disable=SC1090
  source "$DEFAULT_ENV_FILE"
fi

CONSOLE_URL="${CONSOLE_URL:-}"
GATEWAY_URL="${GATEWAY_URL:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --console-url) CONSOLE_URL="${2:-}"; shift 2 ;;
    --gateway-url) GATEWAY_URL="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: bash demo/run-aws-weather-demo.sh [--console-url URL] [--gateway-url URL]"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\n==> %s\n' "$*"; }

say "Running offline syntax and fake-curl verification (make check)"
make check

if [[ -z "$CONSOLE_URL" ]]; then
  read -r -p "Enter your deployed ConsoleURL (https://...): " CONSOLE_URL
fi
if [[ -z "$GATEWAY_URL" ]]; then
  read -r -p "Enter your deployed GatewayURL (https://ID.execute-api.eu-west-3.amazonaws.com): " GATEWAY_URL
fi
export CONSOLE_URL GATEWAY_URL

# Locate Playwright node_modules if installed via npx cache
if ! node -e "require('playwright')" 2>/dev/null; then
  PW_MOD="$(find "$HOME/.npm/_npx" -maxdepth 3 -name "playwright" -type d 2>/dev/null | head -n 1 || true)"
  if [[ -n "$PW_MOD" ]]; then
    export NODE_PATH="$(dirname "$PW_MOD"):${NODE_PATH:-}"
  fi
fi

exec node "$RUNTIME_ROOT/scripts/playwright_weather_demo.js"

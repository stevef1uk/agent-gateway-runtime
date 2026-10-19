#!/bin/bash
# Benchmark the gateway with BOTH policy engines and print the two tables side
# by side:
#
#   1. built-in engine  — the dependency-free Go authorizer (default stack)
#   2. OPA engine       — Rego evaluated by `opa eval` (the docker-compose.opa.yml
#                         override sets AUTHZ_POLICY_ENGINE=opa)
#
# Both runs use the same benchmark tool (demo/bench, a self-contained Go module),
# which auto-detects and reports the active engine. The stack is left on the
# built-in engine when the script finishes.
#
# Usage:
#   ./bench-engines.sh [-c CONC] [-d DUR] [-w WARMUP]
#
# Locations (override via env):
#   COMPOSE  compose command (default: auto-detected — `docker compose`, else `docker-compose`)
set -euo pipefail

cd "$(dirname "$0")"
BENCH_DIR="$(cd bench && pwd)"

# Prefer the compose plugin; fall back to the standalone docker-compose binary.
# COMPOSE may be a multi-word command ("docker compose"), so split it into an
# array — a quoted "$COMPOSE" would look for a binary literally named
# "docker compose" and fail on hosts that only have the plugin.
if [ -z "${COMPOSE:-}" ]; then
  COMPOSE="docker compose"
  if ! docker compose version >/dev/null 2>&1; then
    COMPOSE="docker-compose"
  fi
fi
read -ra COMPOSE <<< "$COMPOSE"

# The PEP's published host port may differ from 8080 (a local OpenShell
# gateway often owns :8080). Compose reads demo/.env; the bench must too, so
# the load it generates targets the same port the stack publishes.
if [ -z "${GATEWAY_HOST_PORT:-}" ] && [ -f .env ]; then
  GATEWAY_HOST_PORT="$(sed -n 's/^GATEWAY_HOST_PORT=//p' .env | tail -1)"
fi
GATEWAY_URL="http://localhost:${GATEWAY_HOST_PORT:-8080}"

CONC=20; DUR=10s; WARM=2s
while [ $# -gt 0 ]; do
  case "$1" in
    -c) CONC="$2"; shift 2 ;;
    -d) DUR="$2"; shift 2 ;;
    -w) WARM="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -f "$BENCH_DIR/main.go" ] || { echo "benchmark tool not found at $BENCH_DIR" >&2; exit 1; }

run_bench() {
  ( cd "$BENCH_DIR" && go run . -c "$CONC" -d "$DUR" -w "$WARM" -gateway "$GATEWAY_URL" )
}

# --no-deps: only authz/web are recreated. `web` depends on `gateway`, and
# without --no-deps compose would recreate the gateway from the base file
# alone, silently dropping any overlay it was started with (e.g. the egress
# overlay's GATEWAY_PROXY_ADDR). The bench switches policy engines, not the
# running topology.
echo "### engine: built-in (Go authorizer)"
"${COMPOSE[@]}" -f docker-compose.yml up -d --no-deps authz web >/dev/null
sleep 3
run_bench

echo
echo "### engine: OPA (Rego via opa eval)"
"${COMPOSE[@]}" -f docker-compose.yml -f docker-compose.opa.yml up -d --no-deps authz web >/dev/null
sleep 3
run_bench

echo
echo "restoring the built-in engine"
"${COMPOSE[@]}" -f docker-compose.yml up -d --no-deps authz web >/dev/null

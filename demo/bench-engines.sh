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
if [ -z "${COMPOSE:-}" ]; then
  COMPOSE="docker compose"
  if ! docker compose version >/dev/null 2>&1; then
    COMPOSE="docker-compose"
  fi
fi

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
  ( cd "$BENCH_DIR" && go run . -c "$CONC" -d "$DUR" -w "$WARM" )
}

echo "### engine: built-in (Go authorizer)"
"$COMPOSE" -f docker-compose.yml up -d authz web >/dev/null
sleep 3
run_bench

echo
echo "### engine: OPA (Rego via opa eval)"
"$COMPOSE" -f docker-compose.yml -f docker-compose.opa.yml up -d authz web >/dev/null
sleep 3
run_bench

echo
echo "restoring the built-in engine"
"$COMPOSE" -f docker-compose.yml up -d authz web >/dev/null

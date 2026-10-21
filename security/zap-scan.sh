#!/bin/bash
# OWASP ZAP security scan of the demo stack's core containers.
#
# For each core service (gateway, authz, tokensvc, web, demoapi) it runs the
# official ZAP baseline scan (`zap-baseline.py` inside the zaproxy/zap-stable
# image) against the service's published port, and writes the Markdown report
# for every target into security/results/ — one file per service, overwritten
# on every run so the folder always holds the latest reports (Markdown because
# the git UI renders it; HTML/JSON are opt-in extras, see below).
#
# The demo stack is brought up automatically (cd demo && docker compose up -d)
# before scanning — each ZAP container reaches its target over the host
# network:
#
#   ./security/zap-scan.sh
#
# What each report is: the baseline scan is a quick, passive-leaning scan —
# it spiders the target, runs the passive scanners, and flags missing
# security headers, cookie flags, TLS/config issues and (with -a) known
# vulnerables. It does NOT attempt forms/auth or active exploitation; point
# the full scan at a service with:
#
#   FULL=1 ./security/zap-scan.sh
#
# Overridable via env:
#   ZAP_IMAGE   ZAP docker image        (default zaproxy/zap-stable)
#   COMPOSE     compose command         (default `docker compose`, else `docker-compose`)
#   TARGETS     "name=port ..."         (default: the five core services)
#   GATEWAY_HOST_PORT  host port of the gateway PEP (default: demo/.env
#                      value, else 8080)
#   WAIT        seconds to wait for a target's /healthz (default 120)
#   HTML=1      also write .html reports next to the .md ones
#   JSON=1      also write .json reports next to the .md ones
#
# Exit code: 0 if every scan ran and no target was unreachable; 1 if any
# target was unreachable or a scan errored. (Alert findings alone do not
# fail the run — read the reports.) Set FAIL_ON_ALERTS=1 to fail when any
# scan reports an ALERT baseline level or worse.
set -euo pipefail

cd "$(dirname "$0")/.."
RESULTS_ROOT="security/results"
ZAP_IMAGE="${ZAP_IMAGE:-zaproxy/zap-stable}"
WAIT="${WAIT:-120}"
FAIL_ON_ALERTS="${FAIL_ON_ALERTS:-0}"

# The core containers of the demo stack and their published host ports
# (demo/docker-compose.yml). Dex :5556, redis and postgres are third-party
# supporting services with no published host ports — excluded by default.
# The Demo 9 MCP services (mcpsrv=8091, the gateway-mcp PEP=8085) are in the
# default list too — scan only a subset with e.g.
#   TARGETS="mcpsrv=8091 gateway-mcp=8085" ./security/zap-scan.sh
if [ -z "${TARGETS:-}" ]; then
  # The gateway's published PEP port may differ from 8080 (an OpenShell
  # gateway often owns :8080; demo/.env carries the override used by compose
  # and demo/bench-engines.sh).
  GW_PORT="${GATEWAY_HOST_PORT:-}"
  if [ -z "$GW_PORT" ] && [ -f demo/.env ]; then
    GW_PORT="$(sed -n 's/^GATEWAY_HOST_PORT=//p' demo/.env | tail -1)"
  fi
  TARGETS=(gateway="${GW_PORT:-8080}" gateway-mcp=8085 authz=8081 tokensvc=8082 web=8083 demoapi=8090 mcpsrv=8091)
else
  read -ra TARGETS <<< "$TARGETS"
fi

command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }

# Prefer the compose plugin; fall back to the standalone docker-compose binary
# (same detection as demo/bench-engines.sh). COMPOSE may be multi-word.
if [ -z "${COMPOSE:-}" ]; then
  COMPOSE="docker compose"
  if ! docker compose version >/dev/null 2>&1; then
    COMPOSE="docker-compose"
  fi
fi
read -ra COMPOSE <<< "$COMPOSE"

# Bring the demo stack up before scanning (idempotent — up on a running
# stack is a no-op, so this works on stacks already started with another
# overlay, e.g. the OPA policy playground). The egress overlay is included
# so the gateway's egress proxy (:8088) is part of the scan surface too.
echo "### bringing up the demo stack (base + egress overlay)"
(cd demo && "${COMPOSE[@]}" -f docker-compose.yml -f docker-compose.egress.yml up -d)

RUN_DIR="security/results"
mkdir -p "$RUN_DIR"
echo "### ZAP scan run — latest reports in $RUN_DIR/"

# The scan is only meaningful against a live stack: wait for each /healthz.
wait_for() {
  local name="$1" port="$2" deadline=$((SECONDS + WAIT))
  until curl -fsS -o /dev/null "http://localhost:$port/healthz" 2>/dev/null; do
    if [ "$SECONDS" -ge "$deadline" ]; then
      echo "  $name: /healthz unreachable on :$port after ${WAIT}s" >&2
      echo "  (container failed to become healthy? docker compose ps)" >&2
      return 1
    fi
    sleep 2
done
}

SUMMARY="$RUN_DIR/summary.txt"
printf 'ZAP scan — %s\nimage: %s  mode: %s\n\n' "$(date -u +'%Y-%m-%d %H:%M:%S UTC')" \
  "$ZAP_IMAGE" "$([ "${FULL:-0}" = 1 ] && echo full || echo baseline)" > "$SUMMARY"

FAILED=0
for entry in "${TARGETS[@]}"; do
  name="${entry%%=*}"; port="${entry##*=}"
  url="http://localhost:$port"
  report="$name"
  echo "### scanning $name ($url)"

  if ! wait_for "$name" "$port"; then
    printf '%-10s UNREACHABLE (:%s)\n' "$name" "$port" | tee -a "$SUMMARY"
    FAILED=1
    continue
  fi

  # zap-baseline.py exit codes: 0 = no alerts, 1 = alerts found,
  # 2 = scan failure, 3 = target not reachable.
  # Markdown is the always-written report (the git UI renders .md); the
  # HTML and JSON variants are opt-in extras (HTML=1 / JSON=1).
  cmd=zap-baseline.py
  [ "${FULL:-0}" = 1 ] && cmd=zap-full-scan.py
  zap=("$cmd" -t "$url" -w "$report.md" -I)
  if [ "${HTML:-0}" = 1 ]; then zap+=(-r "$report.html"); fi
  if [ "${JSON:-0}" = 1 ]; then zap+=(-J "$report.json"); fi

  # Reports are written inside the container at /zap/wrk (the directory this
  # ZAP image requires to be mounted for any file-based report option).
  set +e
  docker run --rm --network host \
    -v "$(pwd)/$RUN_DIR:/zap/wrk" \
    "$ZAP_IMAGE" "${zap[@]}" >/dev/null 2>&1
  rc=$?
  set -e

  case "$rc" in
    0) verdict="no alerts";;
    1) verdict="alerts found";;
    2|3) verdict="scan FAILED (rc=$rc)"; FAILED=1;;
    *) verdict="unknown (rc=$rc)"; FAILED=1;;
  esac
  printf '%-10s :%s  %s\n' "$name" "$port" "$verdict" | tee -a "$SUMMARY"
  printf '  reports: %s/%s.md (readable)%s%s\n' "$RUN_DIR" "$name" \
    "$([ "${HTML:-0}" = 1 ] && printf ' + %s/%s.html' "$RUN_DIR" "$name")" \
    "$([ "${JSON:-0}" = 1 ] && printf ' + %s/%s.json' "$RUN_DIR" "$name")" >> "$SUMMARY"

  if [ "$FAIL_ON_ALERTS" = 1 ] && [ "$rc" -eq 1 ]; then
    echo "$name reported alerts (FAIL_ON_ALERTS=1)" >> "$SUMMARY"
    FAILED=1
  fi
done

# The automation framework writes its run plan into the mounted dir — noise
# alongside the reports, so drop it.
rm -f "$RUN_DIR/zap.yaml"

echo
cat "$SUMMARY"
[ "$FAILED" -eq 0 ] && echo "### done — reports in $RUN_DIR/" \
                     || echo "### finished with failures — see $SUMMARY"
exit "$FAILED"

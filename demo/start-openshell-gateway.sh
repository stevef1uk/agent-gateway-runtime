#!/usr/bin/env bash
# start-openshell-gateway.sh — bring the OpenShell gateway up on macOS.
#
# Supported path: the gateway installed by NVIDIA's official installer
#   curl -LsSf https://raw.githubusercontent.com/NVIDIA/OpenShell/main/install.sh | sh
# which registers a brew service (tap nvidia/openshell) whose PKI lives in
# /opt/homebrew/var/openshell/tls. This script restarts that service, re-points
# the gateway's compute driver at docker, re-registers the CLI so cached mTLS
# material matches the live PKI, and rebuilds the `gw-fwd` forwarder that
# sandbox supervisors inside the Docker Desktop VM rely on.
#
# A manually spawned gateway is only a FALLBACK (no brew service present —
# e.g. the homebrew-core formula or a manual binary). It must never fight a
# running brew service; on a service-managed Mac the two PKIs and two
# supervisor setups would permanently conflict (mirror of the 2026-10 BadSignature/duplicate-table incident).
#
# Linux: use demo/start-openshell-gateway-linux.sh instead.
set -euo pipefail
# Docker or Podman — see lib/engine.sh (CONTAINER_ENGINE env override).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/engine.sh"


ENDPOINT="${GATEWAY_ENDPOINT:-https://127.0.0.1:17670}"
GW_NAME="${GATEWAY_NAME:-openshell}"
GW_PORT="${ENDPOINT##*:}"
TLS_BREW_DIR="/opt/homebrew/var/openshell/tls"
TLS_USER_DIR="${HOME}/.config/openshell/tls"
GATEWAY_LOG="${HOME}/.config/openshell/gateway.log"

have() { command -v "$1" >/dev/null 2>&1; }

# --- 1. pick the management mode (and its PKI dir) ------------------------------
MANAGED=0
if have brew && brew services list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qxF openshell; then
  MANAGED=1
fi

if [ "$MANAGED" -eq 1 ]; then
  TLS_DIR="$TLS_BREW_DIR"
  echo "== Restarting the brew-managed OpenShell gateway (label: sh.brew.openshell) =="
  brew services restart nvidia/openshell/openshell 2>/dev/null || brew services restart openshell
fi

if [ "$MANAGED" -eq 0 ]; then
  TLS_DIR="$TLS_USER_DIR"
  echo "== No brew service found — manual gateway launch (fallback) =="
  # Old instances can take a moment to release TCP ${GW_PORT}; kill, wait for
  # full exit (a fixed sleep here made new starts die with EADDRINUSE under
  # set -e), then start. Pattern is specific so it cannot match this script.
  pkill -f 'openshell-gateway --tls-cert' 2>/dev/null || true
  for _ in $(seq 1 10); do
    pgrep -f 'openshell-gateway --tls-cert' >/dev/null 2>&1 || break
    sleep 1
  done

  # Choose the compute driver at start time (docker | podman).
  # Precedence: OPENSHELL_COMPUTE_DRIVER env if already set — no file pin needed.
  export OPENSHELL_COMPUTE_DRIVER="${OPENSHELL_COMPUTE_DRIVER:-docker}"
  mkdir -p "$TLS_DIR" "$(dirname "$GATEWAY_LOG")"
  if [ ! -f "${TLS_DIR}/server/tls.crt" ]; then
    openshell-gateway generate-certs --output-dir "$TLS_DIR" --server-san host.openshell.internal
  fi
  echo "Checking certs in ${TLS_DIR}/server/:"
  ls -la "${TLS_DIR}/server/"
  openshell-gateway \
    --tls-cert "${TLS_DIR}/server/tls.crt" \
    --tls-key "${TLS_DIR}/server/tls.key" \
    --tls-client-ca "${TLS_DIR}/ca.crt" \
    --bind-address 0.0.0.0 \
    > "$GATEWAY_LOG" 2>&1 &
  echo "Gateway started with PID: $!"
fi

# --- 2. wait for the listener (both modes restart asynchronously) ---------------
echo "== Waiting for ${ENDPOINT} (up to 30s) =="
up=0
for _ in $(seq 1 30); do
  if curl -sk -m 2 -o /dev/null "$ENDPOINT" 2>/dev/null; then up=1; break; fi
  sleep 1
done
if [ "$up" -ne 1 ]; then
  echo "✗ gateway not reachable at ${ENDPOINT} after 30s" >&2
  echo "  gateway log (if a log file was used): ${GATEWAY_LOG}" >&2
  tail -n 40 "$GATEWAY_LOG" 2>/dev/null || true
  echo "  brew service status:" >&2
  brew services list 2>/dev/null | grep -i openshell || true
  echo "  last gateway errors on a brew-managed Mac:" >&2
  tail -n 40 /opt/homebrew/var/log/openshell/openshell-gateway.err.log 2>/dev/null || true
  exit 1
fi
echo "✓ gateway listener up"

# A service-managed gateway without the env var needs the schema-v2 pin, or it
# defaults to podman and `sandbox create` fails with "podman API error (500)".
GW_TOML="${HOME}/.config/openshell/gateway.toml"
if [ -f "$GW_TOML" ] && ! grep -q '^compute_driver' "$GW_TOML"; then
  echo "⚠ gateway.toml pins no compute driver — a brew-managed gateway defaults to podman" >&2
  echo "  run demo/openshell-gateway-setup.sh first (it writes compute_driver = \"docker\")" >&2
fi

# --- 3. forward 127.0.0.1:${GW_PORT} inside the Docker VM to the gateway --------
# Supervisor containers inside the Docker Desktop VM dial 127.0.0.1:${GW_PORT}
# in the VM — which is the VM, not the Mac — so a tiny forwarder inside the VM
# bridges them. The target is measured, not assumed: `host.docker.internal`
# reaches Mac services across vpnkit even when the gateway is bound to the
# Mac's loopback only, and it survives LAN-IP changes; the LAN IP is only the
# fallback when the VM cannot resolve/reach host.docker.internal.
if have docker; then
  eng rm -f gw-fwd >/dev/null 2>&1 || true
  socat_target=""
  if eng run --rm --network host curlimages/curl -sk -m 5 -o /dev/null \
      "https://host.docker.internal:${GW_PORT}" 2>/dev/null; then
    socat_target="host.docker.internal:${GW_PORT}"
  else
    IP=$(ipconfig getifaddr "$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')" 2>/dev/null || true)
    if [ -n "$IP" ] && eng run --rm --network host curlimages/curl -sk -m 5 -o /dev/null \
        "https://${IP}:${GW_PORT}" 2>/dev/null; then
      socat_target="${IP}:${GW_PORT}"
    fi
  fi
  if [ -n "$socat_target" ]; then
    eng run -d --name gw-fwd --restart unless-stopped --network host \
      alpine/socat TCP-LISTEN:"$GW_PORT",bind=127.0.0.1,fork,reuseaddr TCP:"${socat_target}" >/dev/null
    echo "✓ gw-fwd forwards Docker-VM 127.0.0.1:${GW_PORT} → ${socat_target}"
  else
    echo "✗ no reachable gateway target from inside the Docker VM — gw-fwd not created" >&2
    echo "  sandbox create will fail; sandbox supervisors only reach the gateway via this path" >&2
    echo "  when bridging fails like this, the gateway is loopback-bound AND the VM cannot reach" >&2
    echo "  host.docker.internal — run the gateway with --bind-address 0.0.0.0 (manual layout)" >&2
  fi
fi

# --- 4. (re)register the CLI so cached mTLS matches the live PKI ---------------
# `gateway add` provisions the registration's CA + client certs from
# OPENSHELL_LOCAL_TLS_DIR; after a gateway reinstall the cached copy goes stale
# (`invalid peer certificate: BadSignature`), so always remove + re-add.
export OPENSHELL_LOCAL_TLS_DIR="$TLS_DIR"
openshell gateway remove "$GW_NAME" >/dev/null 2>&1 || true
openshell gateway remove mac-gateway >/dev/null 2>&1 || true
openshell gateway add --local "$ENDPOINT" --name "$GW_NAME"
openshell gateway select "$GW_NAME"

# --- 5. verify: control plane from the Mac, data path through the VM -----------
openshell status
probe=$(eng run --rm --network host curlimages/curl -sk -m 5 -o /dev/null \
  -w "%{http_code}" "$ENDPOINT" 2>/dev/null || true)
if [ -z "$probe" ] || [ "$probe" = "000" ]; then
  echo "✗ gateway NOT reachable through the Docker VM forwarder (got: ${probe:-none})" >&2
  echo "  check gw-fwd: $ENGINE logs gw-fwd; a restart loop usually means the target above was dead" >&2
  exit 1
fi
echo "✓ VM→Mac data path verified (HTTP ${probe} through gw-fwd; 404 is expected)"

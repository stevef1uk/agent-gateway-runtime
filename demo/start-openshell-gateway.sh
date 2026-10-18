#!/usr/bin/env bash
# start-openshell-gateway.sh — start OpenShell gateway on macOS with Docker Desktop
# Run: chmod +x start-openshell-gateway.sh && ./start-openshell-gateway.sh

set -euo pipefail

# Use absolute paths to avoid tilde expansion issues in background
TLS_DIR="${HOME}/.config/openshell/tls"
CERT_FILE="${TLS_DIR}/server/tls.crt"
KEY_FILE="${TLS_DIR}/server/tls.key"
CA_FILE="${TLS_DIR}/ca.crt"

# 1. Generate TLS certificates
openshell-gateway generate-certs --output-dir "${HOME}/.config/openshell/tls" --server-san host.openshell.internal

# 2. Verify certs exist
echo "Checking certs in ${TLS_DIR}/server/:"
ls -la "${TLS_DIR}/server/"

# 3. Start the gateway (background, with absolute paths)
pkill -f openshell-gateway 2>/dev/null; sleep 1
export OPENSHELL_COMPUTE_DRIVER=docker
export OPENSHELL_LOCAL_TLS_DIR="${HOME}/.config/openshell/tls"

openshell-gateway \
  --tls-cert "${TLS_DIR}/server/tls.crt" \
  --tls-key "${TLS_DIR}/server/tls.key" \
  --tls-client-ca "${TLS_DIR}/ca.crt" \
  --bind-address 0.0.0.0 \
  > "${HOME}/.config/openshell/gateway.log" 2>&1 &

GATEWAY_PID=$!
echo "Gateway started with PID: ${GATEWAY_PID}"

# 4. Forward 127.0.0.1:17670 inside the Docker VM to the gateway on your Mac
docker rm -f gw-fwd 2>/dev/null
IP=$(ipconfig getifaddr $(route -n get default | awk '/interface:/{print $2}'))
docker run -d --name gw-fwd --restart unless-stopped --network host \
  alpine/socat TCP-LISTEN:17670,bind=127.0.0.1,fork,reuseaddr TCP:${IP}:17670

# 6. Register and select (https + --local)
sleep 3
openshell gateway remove mac-gateway 2>/dev/null || true
openshell gateway add --local https://127.0.0.1:17670 --name mac-gateway
openshell gateway select mac-gateway

# 7. Verify
openshell status
docker run --rm --network host curlimages/curl -sk -m 5 -o /dev/null -w "%{http_code}\n" https://127.0.0.1:17670   # expect 404
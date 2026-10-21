#!/usr/bin/env bash
# start-openshell-gateway-linux.sh — start OpenShell gateway on Linux

set -euo pipefail
# Docker or Podman — see lib/engine.sh (CONTAINER_ENGINE env override).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/engine.sh"


# 1. Generate TLS certificates
openshell-gateway generate-certs --output-dir ~/.config/openshell/tls --server-san host.openshell.internal

# 2. Verify
ls -la ~/.config/openshell/tls/server/    # tls.crt, tls.key

# 3. Choose your compute driver at start time (docker or podman).
#    Precedence: OPENSHELL_COMPUTE_DRIVER env only — no file pin needed.
#    Default: docker  (export OPENSHELL_COMPUTE_DRIVER=podman for rootless)
export OPENSHELL_COMPUTE_DRIVER="${OPENSHELL_COMPUTE_DRIVER:-docker}"
export OPENSHELL_LOCAL_TLS_DIR=~/.config/openshell/tls
openshell-gateway \
  --tls-cert ~/.config/openshell/tls/server/tls.crt \
  --tls-key ~/.config/openshell/tls/server/tls.key \
  --tls-client-ca ~/.config/openshell/tls/ca.crt \
  --bind-address 0.0.0.0 \
  > ~/.config/openshell/gateway.log 2>&1 &

# 4. Register and select
sleep 3
# Self-heal: a prior gateway instance may still hold the registration —
# remove and re-add, so a script re-run is idempotent.
openshell gateway add --local https://127.0.0.1:17670 --name local-gateway 2>/dev/null \
  || { openshell gateway remove local-gateway 2>/dev/null || true; \
       openshell gateway add --local https://127.0.0.1:17670 --name local-gateway; }
openshell gateway select local-gateway

# 5. Verify
openshell status
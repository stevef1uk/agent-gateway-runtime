#!/usr/bin/env bash
# ============================================================================
# Agent Gateway — RFC 9449 (DPoP) & RFC 9396 (RAR) Live Demo Script
#
# Runs an end-to-end test against the local Docker Compose stack:
#   1. Authenticates via Dex SSO
#   2. Creates a human delegation with spend limits
#   3. Generates asymmetric EC key pair and mints RFC 9449 DPoP token
#   4. Verifies stolen DPoP token is rejected (HTTP 401)
#   5. Verifies valid DPoP proof is accepted (HTTP 200)
#   6. Verifies replayed proof is rejected (HTTP 401)
#   7. Mints RFC 9396 RAR least-privilege downscoped token
#   8. Verifies RAR permissions (read allowed, create blocked with HTTP 403)
#   9. Executes combined DPoP + RAR sender-constrained downscoped call
#
# Prereqs:   docker compose up -d (in demo directory)
# Usage:     ./dpop-rar-demo.sh
# ============================================================================

set -euo pipefail
DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"

if command -v go >/dev/null 2>&1; then
  exec go run dpop-rar-demo.go
else
  echo "Error: Go is required to compile and execute the cryptographic DPoP tests." >&2
  exit 1
fi

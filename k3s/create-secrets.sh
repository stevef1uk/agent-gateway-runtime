#!/usr/bin/env bash
set -euo pipefail

NS="${NAMESPACE:-agentgw}"
command -v kubectl >/dev/null || { echo "kubectl is required" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if kubectl -n "$NS" get secret agentgw-secrets >/dev/null 2>&1; then
  if ! kubectl -n "$NS" get secret agentgw-secrets -o json | python3 -c '
import base64
import json
import sys

data = json.load(sys.stdin).get("data", {})
values = {}
for key in ("JWT_SECRET", "GATEWAY_ADMIN_TOKEN"):
    encoded = data.get(key)
    if not encoded:
        raise SystemExit(f"agentgw-secrets is missing {key}; rotate it before deployment")
    values[key] = base64.b64decode(encoded)
    if len(values[key]) < 32:
        raise SystemExit(f"{key} must contain at least 32 random bytes; rotate it before deployment")
if values["JWT_SECRET"] in (
    b"dev-secret-change-in-prod",
    b"agent-gateway-dev-secret-change-in-prod",
    b"agent-gateway-demo-secret-change-in-prod",
    b"local-dev-secret",
):
    raise SystemExit("JWT_SECRET is a published placeholder; rotate it before deployment")
if values["GATEWAY_ADMIN_TOKEN"] in (b"agent-gateway-demo-admin", b"demo-admin-token"):
    raise SystemExit("GATEWAY_ADMIN_TOKEN is a published placeholder; rotate it before deployment")
if values["JWT_SECRET"] == values["GATEWAY_ADMIN_TOKEN"]:
    raise SystemExit("JWT_SECRET and GATEWAY_ADMIN_TOKEN must be independent")
'
  then
    echo "Refusing to deploy with weak or missing agentgw-secrets." >&2
    exit 1
  fi
  echo "agentgw-secrets already exists and passed credential checks; it was not changed."
  exit 0
fi

umask 077
kubectl -n "$NS" create secret generic agentgw-secrets \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=GATEWAY_ADMIN_TOKEN="$(openssl rand -hex 32)" \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 32)"
echo "Created agentgw-secrets with independent random credentials."

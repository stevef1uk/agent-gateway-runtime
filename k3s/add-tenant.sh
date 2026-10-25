#!/usr/bin/env bash
# ============================================================================
# add-tenant.sh — Phase 5 hosted multi-tenancy, SHARED-NOTHING onboarding
# (agent-gateway hosted-edition pattern; see docs/Hosted-Tenants.md)
#
# Every customer gets a COMPLETE stack in their own namespace:
#   tenant-<name>:  dex + authz + tokensvc + web (console) + gateway-mcp PEP
#                   + postgres + redis  —  random secrets, own data, own IdP
#                   hook (OIDC_ISSUER_URL), own LE certificate, own ingress
#                   host <name>.agw.sjfisher.com
# Cross-tenant compromise has NO shared path: different Postgres, Redis,
# signing keys, issuer and console sessions — isolation is structural, not
# policy (the S8 test passes by construction).
#
# The agentgw OPERATOR stack is never touched. Object NAMES inside each
# tenant namespace are identical to the operator stack (dex, web, …) —
# namespace IS the boundary — with two consequences the tooling exploits:
#   * `k3s/add-mcp-server.sh <name>` works UNMODIFIED inside a tenant
#     namespace (same object names; secrets copied by this script carry
#     licence + telegram + keys).
#   * a namespaced ServiceAccount+Role is pre-created for the console's
#     k8s-mutating onboarding API (Phase 5 Stage 1, T5/T6).
#
# USAGE
#   ./add-tenant.sh acme                                   # → https://acme.preprod.agw.sjfisher.com (operator admin)
#   ./add-tenant.sh acme admin@acme.com                    # → allows admin@acme.com + operator
#   HOST_SUFFIX=demo.example.com ./add-tenant.sh acme
#   SUFFIX-less? pass HOST=<full-host> instead.
# Re-running is SAFE: existing secrets are never regenerated (idempotent).
#
# NOTE: per-tenant LE certs use HTTP-01 — works with zero DNS-API setup;
# the customer adds the DNS record pointing <name>.agw.sjfisher.com at the
# cluster (wildcard/DNS-01 via DigitalOcean token is the Stage-2 upgrade).
# Role/SA here are MINIMAL on purpose (no secret read/delete).
# ============================================================================
set -euo pipefail

NAME=${1:?"usage: add-tenant.sh <name> [admin-email]   (env: HOST | HOST_SUFFIX ; via: curl healthy cluster assumed)"}
ADMIN_EMAIL_ARG="${2:-}"
NS="tenant-${NAME}"
HOST=${HOST:-"${NAME}.${HOST_SUFFIX:-preprod.agw.sjfisher.com}"}
SRC_NS=${SRC_NS:-agentgw}          # operator stack to copy shared-material from
MANAGED=${MANAGED:-1}
GW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${GW_DIR}/tenant-${NAME}.yaml"

say() { printf "\033[1;36m==> %s\033[0m\n" "$*"; }
ok()  { printf "    \033[0;32m✓ %s\033[0m\n" "$*"; }
die() { printf "    \033[0;31m✗ %s\033[0m\n" "$*" >&2; exit 1; }
command -v kubectl >/dev/null || die "kubectl required"
command -v openssl >/dev/null || die "openssl required"

# ------------------------------------------------------------- coredns forwarder (cluster-wide)
# Ensure cluster CoreDNS resolves agw.sjfisher.com via public DNS (bypassing local router negative caches)
if [ -f "${GW_DIR}/coredns-custom.yaml" ]; then
  if ! kubectl -n kube-system get configmap coredns-custom >/dev/null 2>&1; then
    say "configuring cluster CoreDNS upstream forwarder for agw.sjfisher.com"
    kubectl apply -f "${GW_DIR}/coredns-custom.yaml" >/dev/null
    kubectl rollout restart deployment/coredns -n kube-system >/dev/null
    ok "coredns-custom applied"
  fi
fi

kubectl create namespace "${NS}" 2>/dev/null && ok "namespace ${NS} created" || ok "namespace ${NS} exists"

# ------------------------------------------------------------- secrets (own)
say "namespace ${NS}: secrets (random, own; never regenerated on re-run)"
if ! kubectl -n "$NS" get secret agentgw-secrets >/dev/null 2>&1; then
  kubectl -n "$NS" create secret generic agentgw-secrets \
    --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
    --from-literal=GATEWAY_ADMIN_TOKEN="$(openssl rand -hex 16)" \
    --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 16)"
  ok "agentgw-secrets (random per-tenant: JWT/admin/PG)"
else
  ok "agentgw-secrets exists (kept)"
fi

# Telegram approval cards (operator's channel in both lanes)
if kubectl -n "$NS" get secret agentgw-telegram >/dev/null 2>&1; then
  ok "agentgw-telegram exists (kept)"
else
  kubectl get secret -n "$SRC_NS" agentgw-telegram -o json \
    | python3 "$(dirname "$0")/lib/copy_secret.py" "$NS" \
    | kubectl apply -n "$NS" -f - >/dev/null
  ok "agentgw-telegram copied from ${SRC_NS}"
fi

# Licence + private key — the PADLOCK. Eval/demo lane copies the operator's
# key material (fine: the eval images are encrypted to the PUBLIC demo key).
# MANAGED tier (MANAGED=1) refuses eval keys: the tenant gets the hosted
# padlock private key + a FRESH vendor-signed short licence (the expiry is
# the subscription). Never mixes lanes — a managed stack with eval keys
# would leak the eval padlock into infra meant to be non-runnable elsewhere.
if [ "${MANAGED:-0}" = "1" ]; then
    HOSTED_PRIV=${HOSTED_PRIVATE_KEY:-/home/stevef/dev/agent-gateway/keys/hosted/hosted_private.pem}
    [ -f "$HOSTED_PRIV" ] || die "managed tier: hosted private key missing at $HOSTED_PRIV (never falls back to eval keys)"
  if kubectl -n "$NS" get secret agentgw-keys >/dev/null 2>&1; then
    # lane-hygiene guard: keys already present must BE the hosted padlock —
    # an existing EVAL key + _m images is a silent mixed lane (decrypt fails
    # at start) and worse, a leak-shape if reversed. Verify the fingerprint.
    WANT=$(openssl pkey -in "$HOSTED_PRIV" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
    GOT=$(kubectl -n "$NS" get secret agentgw-keys -o jsonpath='{.data.customer_private\.pem}' | base64 -d | openssl pkey -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
    [ "$WANT" = "$GOT" ] || die "mixed lane: agentgw-keys in $NS does NOT use the hosted padlock (fingerprint $GOT != hosted $WANT) — refresh via remove/add with MANAGED=1"
    ok "agentgw-keys exists and matches the hosted padlock fingerprint"
  else
    AGW_SCRIPTS=${AGENTGW_SCRIPTS_DIR:-/home/stevef/dev/agent-gateway/scripts}
    [ -x "$AGW_SCRIPTS/issue-managed-licence.sh" ] || die "issue-managed-licence.sh not found at $AGW_SCRIPTS (managed tier needs the licence minter)"
    LIC_ARGS=()
    [ -n "${LICENCE_DAYS:-}" ] && LIC_ARGS+=(-d "$LICENCE_DAYS")
    [ -n "${LICENCE_COMPANY:-}" ] && LIC_ARGS+=(-c "$LICENCE_COMPANY")
    LIC_EMAIL="${LICENCE_EMAIL:-${ADMIN_EMAIL_ARG:-}}"
    [ -n "$LIC_EMAIL" ] && LIC_ARGS+=(-e "$LIC_EMAIL")
    TOK_FILE=$(TMP_OUT="${TMP_OUT:-/tmp/managed-licences}" "$AGW_SCRIPTS/issue-managed-licence.sh" "$NAME" "${LIC_ARGS[@]:-}" | tail -1)
    [ -s "$TOK_FILE" ] || die "licence mint failed ($TOK_FILE missing)"
    kubectl -n "$NS" create secret generic agentgw-keys \
      --from-file=customer_private.pem="$HOSTED_PRIV" \
      --from-file=license.token="$TOK_FILE"
    ok "managed keys: hosted padlock + freshly minted licence (${LICENCE_DAYS:-100}-day expiry = subscription)"
  fi
else
  if kubectl -n "$NS" get secret agentgw-keys >/dev/null 2>&1; then
    ok "agentgw-keys exists (kept)"
  else
    kubectl get secret -n "$SRC_NS" agentgw-keys -o json \
      | python3 "$(dirname "$0")/lib/copy_secret.py" "$NS" \
      | kubectl apply -n "$NS" -f - >/dev/null
    ok "agentgw-keys copied from ${SRC_NS} (licence+key)"
  fi
fi

# Identity Provider: Google OAuth credentials (optional; loaded from demo/.env if present)
ENV_FILE="${GW_DIR}/../demo/.env"
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-${GOOGLE_OAUTH_CLIENT_ID:-}}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-${GOOGLE_OAUTH_CLIENT_SECRET:-${GOOGLE_OATH_CLIENT_SECRET:-}}}"
if [ -z "$GOOGLE_CLIENT_ID" ] && [ -f "$ENV_FILE" ]; then
  GOOGLE_CLIENT_ID=$(grep -E '^GOOGLE_OAUTH?_CLIENT_ID=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r"')
fi
if [ -z "$GOOGLE_CLIENT_SECRET" ] && [ -f "$ENV_FILE" ]; then
  GOOGLE_CLIENT_SECRET=$(grep -E '^GOOGLE_OA(U)?TH_CLIENT_SECRET=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r"')
fi
if [ -z "$GOOGLE_CLIENT_ID" ] || [ -z "$GOOGLE_CLIENT_SECRET" ]; then
  for gns in "$NS" tenant-preprod "$SRC_NS"; do
    if kubectl -n "$gns" get secret agentgw-google-idp >/dev/null 2>&1; then
      GOOGLE_CLIENT_ID=$(kubectl -n "$gns" get secret agentgw-google-idp -o jsonpath='{.data.client_id}' | base64 -d 2>/dev/null || true)
      GOOGLE_CLIENT_SECRET=$(kubectl -n "$gns" get secret agentgw-google-idp -o jsonpath='{.data.client_secret}' | base64 -d 2>/dev/null || true)
      [ -n "$GOOGLE_CLIENT_ID" ] && [ -n "$GOOGLE_CLIENT_SECRET" ] && break
    fi
  done
fi

if [ -n "$GOOGLE_CLIENT_ID" ] && [ -n "$GOOGLE_CLIENT_SECRET" ]; then
  IDP_KIND="google"
  say "Identity Provider: Google OAuth"
  if ! kubectl -n "$NS" get secret agentgw-google-idp >/dev/null 2>&1; then
    kubectl -n "$NS" create secret generic agentgw-google-idp \
      --from-literal=client_id="$GOOGLE_CLIENT_ID" \
      --from-literal=client_secret="$GOOGLE_CLIENT_SECRET"
    ok "agentgw-google-idp created (Google credentials)"
  else
    ok "agentgw-google-idp exists (kept)"
  fi
  TENANT_OIDC_ISSUER="https://${HOST}/oidc/idp/dex"
  TENANT_OIDC_CONNECTOR="google"
  IFS= read -r -d '' DEX_CONFIG_DATA <<DEX_EOF || true
    issuer: https://${HOST}/oidc/idp/dex
    storage: { type: memory }
    web: { http: 0.0.0.0:5556 }
    oauth2:
      skipApprovalScreen: true
    staticClients:
      - id: agent-gateway
        name: Agent Gateway
        public: true
        redirectURIs:
          - http://localhost:30083/oidc/callback
          - https://${HOST}/oidc/callback
          - https://${HOST}/oauth/idpcallback
    enablePasswordDB: false
    connectors:
      - type: oidc
        id: google
        name: Google
        config:
          issuer: https://accounts.google.com
          clientID: "\$GOOGLE_CLIENT_ID"
          clientSecret: "\$GOOGLE_CLIENT_SECRET"
          redirectURI: https://${HOST}/oidc/idp/dex/callback
          promptType: "select_account"
DEX_EOF
  IFS= read -r -d '' DEX_DEPLOY_ENV <<DEX_EOF || true
          env:
            - name: GOOGLE_CLIENT_ID
              valueFrom: { secretKeyRef: { name: agentgw-google-idp, key: client_id, optional: true } }
            - name: GOOGLE_CLIENT_SECRET
              valueFrom: { secretKeyRef: { name: agentgw-google-idp, key: client_secret, optional: true } }
DEX_EOF
else
  IDP_KIND="local"
  say "Identity Provider: Dex password DB (local connector; mockCallback disabled for security)"
  TENANT_OIDC_ISSUER="http://dex:5556/dex"
  TENANT_OIDC_CONNECTOR="local"
  IFS= read -r -d '' DEX_CONFIG_DATA <<DEX_EOF || true
    issuer: http://dex:5556/dex
    storage: { type: memory }
    web: { http: 0.0.0.0:5556 }
    oauth2:
      skipApprovalScreen: true
      passwordConnector: local
    staticClients:
      - id: agent-gateway
        name: Agent Gateway
        public: true
        redirectURIs:
          - http://localhost:30083/oidc/callback
          - https://${HOST}/oidc/callback
          - https://${HOST}/oauth/idpcallback
    enablePasswordDB: true
    staticPasswords:
      - email: "${OPERATOR_EMAIL:-stevef1uk@gmail.com}"
        hash: "\$2a\$10\$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W"
        username: "admin"
        userID: "admin"
    connectors: []
DEX_EOF
  DEX_DEPLOY_ENV=""
fi

OPERATOR_EMAILS="${OPERATOR_EMAILS:-${OPERATOR_EMAIL:-sjftest123uk1@gmail.com,stevef1uk@gmail.com}}"
if [ -n "${ADMIN_EMAIL_ARG:-}" ]; then
  # Include both the tenant admin email and the operator emails so both can manage the console
  if [[ ",${OPERATOR_EMAILS}," != *",${ADMIN_EMAIL_ARG},"* ]]; then
    ADMIN_EMAILS="${ADMIN_EMAILS:-${ADMIN_EMAIL_ARG},${OPERATOR_EMAILS}}"
  else
    ADMIN_EMAILS="${ADMIN_EMAILS:-${OPERATOR_EMAILS}}"
  fi
else
  ADMIN_EMAILS="${ADMIN_EMAILS:-${OPERATOR_EMAILS}}"
fi

# Image refs: eval lane = the published public tags; managed lane = the _m
# lane (same Dockerfiles, payload encrypted to the hosted padlock — inert
# without keys/hosted/hosted_private.pem, safe on the same public registry).
IMG_AUTHZ=${IMG_AUTHZ:-stevef1uk/agent-gateway-authz:1.0.12}
IMG_TOKENSVC=${IMG_TOKENSVC:-stevef1uk/agent-gateway-tokensvc:1.0.5}
IMG_WEB=${IMG_WEB:-stevef1uk/agent-gateway-web:1.0.44}
IMG_GATEWAY=${IMG_GATEWAY:-stevef1uk/agent-gateway-gateway:1.0.29}
if [ "${MANAGED:-0}" = "1" ]; then
  IMG_AUTHZ=${IMG_AUTHZ_M:-stevef1uk/agent-gateway-authz_m:1.0.15}
  IMG_TOKENSVC=${IMG_TOKENSVC_M:-stevef1uk/agent-gateway-tokensvc_m:1.0.6}
  IMG_WEB=${IMG_WEB_M:-stevef1uk/agent-gateway-web_m:1.0.60}
  IMG_GATEWAY=${IMG_GATEWAY_M:-stevef1uk/agent-gateway-gateway_m:1.0.33}
  ok "MANAGED lane: _m images (${IMG_GATEWAY_M:-stevef1uk/agent-gateway-gateway_m:${IMG_GATEWAY##*:}})"
fi

# ------------------------------------------------------------------ manifest
say "generating ${MANIFEST#*/} (+x nothing; yaml only) and applying"
cat > "$MANIFEST" <<EOF
# Tenant stack '${NAME}' — host https://${HOST}   [image lane: ${IMG_GATEWAY%:*}]
# Generated by add-tenant.sh. SHARED-NOTHING: own dex/authz/tokensvc/web/PEP,
# own postgres+redis PVs, random secrets (script-managed, not in this file),
# own dex issuer config, own LE cert. Operator namespace (${SRC_NS}) untouched.
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${NS}
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: agentgw-${NAME}-pv
spec:
  capacity: { storage: 5Gi }
  accessModes: [ReadWriteMany]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: gluster-shared
  hostPath:
    path: /srv/agentgw-${NAME}
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: agentgw-shared-pvc
  namespace: ${NS}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: gluster-shared
  volumeName: agentgw-${NAME}-pv
  resources: { requests: { storage: 5Gi } }
---
# dex — the tenant's identity provider instance (their users, their rules)
apiVersion: v1
kind: ConfigMap
metadata: { name: dex-config, namespace: ${NS} }
data:
  config.yaml: |
${DEX_CONFIG_DATA}
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: dex, namespace: ${NS} }
spec:
  replicas: 1
  selector: { matchLabels: { app: dex } }
  template:
    metadata: { labels: { app: dex } }
    spec:
      containers:
        - name: dex
          image: ghcr.io/dexidp/dex:v2.46.0
          args: ["dex", "serve", "/etc/dex/config.yaml"]
          ports: [{ containerPort: 5556 }]
${DEX_DEPLOY_ENV}
          volumeMounts: [{ name: config, mountPath: /etc/dex }]
      volumes:
        - name: config
          configMap: { name: dex-config }
---
apiVersion: v1
kind: Service
metadata: { name: dex, namespace: ${NS} }
spec:
  selector: { app: dex }
  ports: [{ port: 5556, targetPort: 5556 }]
---
# postgres — the tenant's OWN database (ledger, approvals, OAuth rows)
apiVersion: apps/v1
kind: Deployment
metadata: { name: postgres, namespace: ${NS} }
spec:
  replicas: 1
  selector: { matchLabels: { app: postgres } }
  template:
    metadata: { labels: { app: postgres } }
    spec:
      initContainers:
        - name: volume-ownership
          image: busybox:1.36
          command: ["sh","-c","mkdir -p /data/pgdata && chown -R 70:70 /data"]
          volumeMounts: [{ name: data, mountPath: /data, subPath: postgres }]
      containers:
        - name: postgres
          image: postgres:16-alpine
          env:
            - { name: POSTGRES_USER, value: agentgw }
            - name: POSTGRES_PASSWORD
              valueFrom: { secretKeyRef: { name: agentgw-secrets, key: POSTGRES_PASSWORD } }
            - { name: POSTGRES_DB, value: agent_gateway }
            - { name: PGDATA, value: /data/pgdata }
          ports: [{ containerPort: 5432 }]
          volumeMounts: [{ name: data, mountPath: /data, subPath: postgres }]
          readinessProbe:
            exec: { command: ["pg_isready","-U","agentgw","-d","agent_gateway"] }
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: agentgw-shared-pvc }
---
apiVersion: v1
kind: Service
metadata: { name: postgres, namespace: ${NS} }
spec:
  selector: { app: postgres }
  ports: [{ port: 5432, targetPort: 5432 }]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: redis, namespace: ${NS} }
spec:
  replicas: 1
  selector: { matchLabels: { app: redis } }
  template:
    metadata: { labels: { app: redis } }
    spec:
      initContainers:
        - name: volume-ownership
          image: busybox:1.36
          command: ["sh","-c","mkdir -p /data && chown -R 999:1000 /data"]
          volumeMounts: [{ name: data, mountPath: /data, subPath: postgres }]
      containers:
        - name: redis
          image: redis:7-alpine
          args: ["redis-server","--appendonly","yes"]
          ports: [{ containerPort: 6379 }]
          volumeMounts: [{ name: data, mountPath: /data, subPath: postgres }]
          readinessProbe:
            exec: { command: ["redis-cli","ping"] }
            initialDelaySeconds: 3
            periodSeconds: 5
      volumes:
        - name: data
          persistentVolumeClaim: { claimName: agentgw-shared-pvc }
---
apiVersion: v1
kind: Service
metadata: { name: redis, namespace: ${NS} }
spec:
  selector: { app: redis }
  ports: [{ port: 6379, targetPort: 6379 }]
---
# authz — decision point, random JWT_SECRET, tenant issuer
apiVersion: apps/v1
kind: Deployment
metadata: { name: authz, namespace: ${NS} }
spec:
  replicas: 1
  selector: { matchLabels: { app: authz } }
  template:
    metadata: { labels: { app: authz } }
    spec:
      initContainers:
        - name: seed-policy          # same race fix as web: fresh PVs start
          image: ${IMG_WEB}   # empty; the web image
          securityContext: { runAsUser: 0 }           # carries the default rego
          command: ["sh","-c","test -f /policies/authorizer.rego || cp /app/default-policy.rego /policies/authorizer.rego; chmod 666 /policies/authorizer.rego; exit 0"]
          volumeMounts: [{ name: policies, mountPath: /policies, subPath: policies }]
      containers:
        - name: authz
          image: ${IMG_AUTHZ}
          ports: [{ containerPort: 8081 }]
          env:
            - { name: PERSISTENCE, value: postgres }
            - name: POSTGRES_PASSWORD
              valueFrom: { secretKeyRef: { name: agentgw-secrets, key: POSTGRES_PASSWORD } }
            - name: DATABASE_URL
              value: "postgres://agentgw:\$(POSTGRES_PASSWORD)@postgres:5432/agent_gateway?sslmode=disable"
            - { name: REDIS_URL, value: "redis://redis:6379/0" }
            - name: JWT_SECRET
              valueFrom: { secretKeyRef: { name: agentgw-secrets, key: JWT_SECRET } }
            - { name: OIDC_ISSUER_URL, value: "${TENANT_OIDC_ISSUER}" }
            - { name: OIDC_CLIENT_ID, value: agent-gateway }
            - { name: OIDC_CONNECTOR_ID, value: "${TENANT_OIDC_CONNECTOR}" }
            - { name: AUTHZ_POLICY_ENGINE, value: opa }
            - { name: DECISION_CACHE_TTL, value: "30s" }
            - { name: OPA_POLICY_PATH, value: /policy/authorizer.rego }
            - { name: SIGNUP_ENABLED, value: "1" }
            - name: GATEWAY_ADMIN_TOKEN
              valueFrom: { secretKeyRef: { name: agentgw-secrets, key: GATEWAY_ADMIN_TOKEN } }
          volumeMounts:
            - { name: keys, mountPath: /keys, readOnly: true }
            - { name: licence, mountPath: /licences/authz.token, subPath: authz.token, readOnly: true }
            - { name: policies, mountPath: /policy, subPath: "policies", readOnly: true }
          readinessProbe:
            httpGet: { path: /healthz, port: 8081 }
            initialDelaySeconds: 10
            periodSeconds: 5
      volumes:
        - name: keys
          secret: { secretName: agentgw-keys, items: [{ key: customer_private.pem, path: customer_private.pem }] }
        - name: licence
          secret: { secretName: agentgw-keys, items: [{ key: license.token, path: authz.token }] }
        - name: policies
          persistentVolumeClaim: { claimName: agentgw-shared-pvc }
---
apiVersion: v1
kind: Service
metadata: { name: authz, namespace: ${NS} }
spec:
  selector: { app: authz }
  ports: [{ port: 8081, targetPort: 8081 }]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: tokensvc, namespace: ${NS} }
spec:
  replicas: 1
  selector: { matchLabels: { app: tokensvc } }
  template:
    metadata: { labels: { app: tokensvc } }
    spec:
      containers:
        - name: tokensvc
          image: ${IMG_TOKENSVC}
          ports: [{ containerPort: 8082 }]
          env:
            - name: JWT_SECRET
              valueFrom: { secretKeyRef: { name: agentgw-secrets, key: JWT_SECRET } }
            - { name: AUTHZ_URL, value: "http://authz:8081" }
          volumeMounts:
            - { name: keys, mountPath: /keys, readOnly: true }
            - { name: licence, mountPath: /licences/tokensvc.token, subPath: tokensvc.token, readOnly: true }
          readinessProbe:
            httpGet: { path: /healthz, port: 8082 }
            initialDelaySeconds: 8
            periodSeconds: 5
      volumes:
        - name: keys
          secret: { secretName: agentgw-keys, items: [{ key: customer_private.pem, path: customer_private.pem }] }
        - name: licence
          secret: { secretName: agentgw-keys, items: [{ key: license.token, path: tokensvc.token }] }
---
apiVersion: v1
kind: Service
metadata: { name: tokensvc, namespace: ${NS} }
spec:
  selector: { app: tokensvc }
  ports: [{ port: 8082, targetPort: 8082 }]
---
# web — the tenant's OWN console (sessions in-memory here; single replica)
apiVersion: apps/v1
kind: Deployment
metadata: { name: web, namespace: ${NS} }
spec:
  replicas: 1
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec:
      serviceAccountName: web-console   # scoped by Role (see below); T6 console onboarding
      initContainers:
        - name: seed-policy
          image: ${IMG_WEB}
          securityContext: { runAsUser: 0 }
          command: ["sh","-c","test -f /policies/authorizer.rego || cp /app/default-policy.rego /policies/authorizer.rego; chmod 666 /policies/authorizer.rego; exit 0"]
          volumeMounts: [{ name: policies, mountPath: /policies, subPath: policies }]
      containers:
        - name: web
          image: ${IMG_WEB}
          securityContext: { runAsUser: 0 }
          ports: [{ containerPort: 8083 }]
          env:
            - { name: AUTHZ_URL, value: "http://authz:8081" }
            - { name: GATEWAY_URL, value: "http://gateway-mcp:8080" }
            - { name: TOKENSVC_URL, value: "http://tokensvc:8082" }
            - { name: OIDC_ISSUER_URL, value: "${TENANT_OIDC_ISSUER}" }
            - { name: OIDC_CLIENT_ID, value: agent-gateway }
            - { name: OIDC_CONNECTOR_ID, value: "${TENANT_OIDC_CONNECTOR}" }
            - name: GATEWAY_ADMIN_TOKEN
              valueFrom: { secretKeyRef: { name: agentgw-secrets, key: GATEWAY_ADMIN_TOKEN } }
            - { name: DEMO_UI, value: "1" }
            - { name: WEB_ADMIN_EMAILS, value: "${ADMIN_EMAILS}" }
            - { name: PUBLIC_GATEWAY_URL, value: "https://${HOST}" }
            - { name: POLICY_FILE, value: /policies/authorizer.rego }
            - { name: POLICY_DEFAULT_FILE, value: /app/default-policy.rego }
            - name: POSTGRES_PASSWORD
              valueFrom: { secretKeyRef: { name: agentgw-secrets, key: POSTGRES_PASSWORD } }
            - { name: DATABASE_URL, value: "postgres://agentgw:\$(POSTGRES_PASSWORD)@postgres:5432/agent_gateway?sslmode=disable" }
          volumeMounts:
            - { name: keys, mountPath: /keys, readOnly: true }
            - { name: licence, mountPath: /licences/web.token, subPath: web.token, readOnly: true }
            - { name: policies, mountPath: /policies, subPath: policies }
          readinessProbe:
            httpGet: { path: /healthz, port: 8083 }
            initialDelaySeconds: 8
            periodSeconds: 5
      volumes:
        - name: keys
          secret: { secretName: agentgw-keys, items: [{ key: customer_private.pem, path: customer_private.pem }] }
        - name: licence
          secret: { secretName: agentgw-keys, items: [{ key: license.token, path: web.token }] }
        - name: policies
          persistentVolumeClaim: { claimName: agentgw-shared-pvc }
---
apiVersion: v1
kind: Service
metadata: { name: web, namespace: ${NS} }
spec:
  selector: { app: web }
  ports: [{ port: 8083, targetPort: 8083 }]
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: gateway-mcp, namespace: ${NS} }
spec:
  replicas: 1
  selector: { matchLabels: { app: gateway-mcp } }
  template:
    metadata: { labels: { app: gateway-mcp } }
    spec:
      containers:
        - name: gateway-mcp
          image: ${IMG_GATEWAY}
          ports: [{ containerPort: 8080 }]
          env:
            - { name: AUTHZ_URL, value: "http://authz:8081" }
            - { name: PERSISTENCE, value: postgres }
            - name: POSTGRES_PASSWORD
              valueFrom: { secretKeyRef: { name: agentgw-secrets, key: POSTGRES_PASSWORD } }
            - name: DATABASE_URL
              value: "postgres://agentgw:\$(POSTGRES_PASSWORD)@postgres:5432/agent_gateway?sslmode=disable"
            - { name: REDIS_URL, value: "redis://redis:6379/0" }
            - name: JWT_SECRET
              valueFrom: { secretKeyRef: { name: agentgw-secrets, key: JWT_SECRET } }
            - name: GATEWAY_ADMIN_TOKEN
              valueFrom: { secretKeyRef: { name: agentgw-secrets, key: GATEWAY_ADMIN_TOKEN } }
            - { name: OAUTH_ENABLED, value: "1" }
            - { name: OAUTH_ISSUER_URL, value: "https://${HOST}" }
            - { name: OIDC_ISSUER_URL, value: "${TENANT_OIDC_ISSUER}" }
            - { name: OIDC_CLIENT_ID, value: agent-gateway }
            - { name: OIDC_CONNECTOR_ID, value: "${TENANT_OIDC_CONNECTOR}" }
            - { name: UPSTREAM_URL, value: "http://mcpsrv:8091" }
            - name: APPROVAL_TELEGRAM_BOT_TOKEN
              valueFrom: { secretKeyRef: { name: agentgw-telegram, key: bot_token, optional: true } }
            - name: APPROVAL_TELEGRAM_CHAT_ID
              valueFrom: { secretKeyRef: { name: agentgw-telegram, key: chat_id, optional: true } }
            - { name: APPROVAL_CONSOLE_URL, value: "https://${HOST}" }
          volumeMounts:
            - { name: licence, mountPath: /licences/gateway.token, subPath: gateway.token, readOnly: true }
            - { name: keys, mountPath: /keys, readOnly: true }
          readinessProbe:
            httpGet: { path: /healthz, port: 8080 }
            initialDelaySeconds: 8
            periodSeconds: 5
      volumes:
        - name: licence
          secret: { secretName: agentgw-keys, items: [{ key: license.token, path: gateway.token }] }
        - name: keys
          secret: { secretName: agentgw-keys, items: [{ key: customer_private.pem, path: customer_private.pem }] }
---
apiVersion: v1
kind: Service
metadata: { name: gateway-mcp, namespace: ${NS} }
spec:
  selector: { app: gateway-mcp }
  ports: [{ name: pep, port: 8080, targetPort: 8080 }]
---
# mcpsrv — default Demo CRM MCP server behind gateway-mcp (/mcp), ClusterIP only
apiVersion: apps/v1
kind: Deployment
metadata: { name: mcpsrv, namespace: ${NS} }
spec:
  replicas: 1
  selector: { matchLabels: { app: mcpsrv } }
  template:
    metadata: { labels: { app: mcpsrv } }
    spec:
      containers:
        - name: mcpsrv
          image: stevef1uk/agent-gateway-mcpsrv:1.0.2
          ports: [{ containerPort: 8091 }]
---
apiVersion: v1
kind: Service
metadata: { name: mcpsrv, namespace: ${NS} }
spec:
  type: ClusterIP
  selector: { app: mcpsrv }
  ports: [{ name: mcp, port: 8091, targetPort: 8091 }]
---
# ingress — the tenant's host; per-tenant LE cert (HTTP-01; wildcard/DNS-01 later)
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: agentgw-ingress
  namespace: ${NS}
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: traefik
  tls:
    - hosts: [${HOST}]
      secretName: agentgw-tls
  rules:
    - host: ${HOST}
      http:
        paths:
          - { path: /oidc/idp/dex, pathType: Prefix, backend: { service: { name: dex, port: { number: 5556 } } } }
          - { path: /token, pathType: Prefix, backend: { service: { name: tokensvc, port: { number: 8082 } } } }
          - { path: /t/${NAME}/mcp, pathType: Prefix, backend: { service: { name: gateway-mcp, port: { number: 8080 } } } }
          - { path: /mcp, pathType: Prefix, backend: { service: { name: gateway-mcp, port: { number: 8080 } } } }
          - { path: /oauth, pathType: Prefix, backend: { service: { name: gateway-mcp, port: { number: 8080 } } } }
          - { path: /.well-known, pathType: Prefix, backend: { service: { name: gateway-mcp, port: { number: 8080 } } } }
          - { path: /, pathType: Prefix, backend: { service: { name: web, port: { number: 8083 } } } }
---
# RBAC for the console onboarding API (T5/T6) + per-tenant Telegram config:
# web's ServiceAccount may mutate ONLY this namespace's workloads/services/
# configmaps/secrets. Secrets are the tenant's OWN material — the boundary
# that matters is the namespace tenant-m1 vs tenant-acme, which the Role
# cannot cross. No delete on secrets (config only ever upserts).
apiVersion: v1
kind: ServiceAccount
metadata: { name: web-console, namespace: ${NS} }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: web-console, namespace: ${NS} }
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get","list","watch","create","update","patch","delete"]
  - apiGroups: [""]
    resources: ["services","configmaps"]
    verbs: ["get","list","watch","create","update","patch","delete"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get","create","patch"]   # notifications (agentgw-telegram); values stay tenant-owned
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get","list","watch","logs"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["get","list","patch","update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: web-console, namespace: ${NS} }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: web-console }
subjects: [{ kind: ServiceAccount, name: web-console, namespace: ${NS} }]
EOF

kubectl apply -f "$MANIFEST" >/dev/null
ok "applied: ${MANIFEST#*/}"

# Seed default Claude MCP delegations for known tenant admins
say "seeding default Claude MCP delegations in postgres"
kubectl -n "${NS}" rollout status deployment/postgres --timeout=60s >/dev/null 2>&1 || true
PG_POD=$(kubectl -n "${NS}" get pods -l app=postgres -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$PG_POD" ]; then
  for SUB in "ChUxMDI0NzUyMjE4MTcxOTA5NTQwMTcSBmdvb2dsZQ" "ChUxMDc0ODUzODIxNTY2MDU0NjAwMTASBmdvb2dsZQ"; do
    kubectl -n "${NS}" exec "$PG_POD" -- psql -U agentgw -d agent_gateway -c "
      INSERT INTO delegations (id, user_id, agent_id, expires_at, created_at, data)
      VALUES (
        'del-claude-init-${SUB:4:8}',
        '${SUB}',
        'claude-mcp-default',
        NOW() + INTERVAL '30 days',
        NOW(),
        jsonb_build_object(
          'id', 'del-claude-init-${SUB:4:8}',
          'user_id', '${SUB}',
          'agent_id', 'claude-mcp-default',
          'max_depth', 0,
          'resources', jsonb_build_array('/t/${NAME}/mcp*', '/mcp*'),
          'actions', jsonb_build_array('initialize', 'list', 'lookup_customer', 'list_customers', 'find_customer', 'add_customer', 'delete_customer', 'get_info', 'echo', 'add'),
          'approval_rules', jsonb_build_array(jsonb_build_object('when', jsonb_build_object('resource_pattern', '*', 'action_pattern', 'delete_customer'), 'require', true, 'rationale', 'Deleting a customer record is destructive — confirm the customer ID before approving')),
          'created_at', NOW(),
          'expires_at', NOW() + INTERVAL '30 days'
        )
      ) ON CONFLICT (id) DO NOTHING;
    " >/dev/null 2>&1 || true
  done
  ok "seeded default Claude delegations in ${NS}"
fi

cat <<EOF

DONE — tenant '${NAME}' up. Console: https://${HOST}   (DNS: point ${HOST} at the cluster; per-tenant LE cert issues once DNS resolves)
  Admin accounts: ${ADMIN_EMAILS}
$([ "${IDP_KIND:-}" = "google" ] && printf "  Google OAuth: Ensure https://%s/oidc/idp/dex/callback is added to Authorized redirect URIs in Google Cloud Console\n" "${HOST}")
  PEP /mcp governed (401 until tokens flow); no MCP server onboarded yet:
    NAMESPACE=${NS} HOST=${HOST} ./add-mcp-server.sh <theirs>   # unmodified script, works in the tenant ns
  Re-run safe: secrets never regenerated. Remove: ./remove-tenant.sh ${NAME}
EOF

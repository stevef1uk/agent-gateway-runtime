# Agent Gateway on k3s

Deploy the full stack (authz, tokensvc, gateway, console, OIDC provider,
Postgres, Redis) into the `agentgw` namespace. The checked-in Dex mock is for
private development only; public use requires a trusted external OIDC provider.

## Layout

| Service | Image | Exposure |
|---|---|---|
| web (console + playground) | `agent-gateway-web_m:1.0.47` | NodePort **30083** |
| gateway (enforcement) | `agent-gateway-gateway_m:1.0.31` | NodePort **30080** + **30088** (egress proxy) |
| authz (decision point) | `agent-gateway-authz_m:1.0.13` | NodePort **30081** |
| tokensvc (minting) | `agent-gateway-tokensvc_m:1.0.6` | NodePort **30082** |
| dex (local OIDC IdP) | `dexidp/dex:v2.46.0` | ClusterIP only (browser traffic is proxied via `/oidc/idp/…`) |
| postgres / redis | official | ClusterIP, pinned to one node on local storage |

### Egress proxy (gateway images ≥ 1.0.22)

The gateway also runs a **forward proxy** listener (`GATEWAY_PROXY_ADDR`
= `:8088`, node-exposed on **30088**): an agent runtime (an NVIDIA
OpenShell sandbox, OpenClaw, or any tool that honours `HTTP_PROXY`)
routes its **entire outbound traffic** through it — every destination is
one delegated, audited, approval-gated decision (host = resource,
method/CONNECT = action). The sandbox side points its upstream proxy at
the node:

```bash
# on the OpenShell gateway host (~/.config/openshell/gateway.toml):
[openshell.drivers.podman]
https_proxy = "http://192.168.1.74:30088"
proxy_auth_file = "/root/.config/openshell/upstream-proxy-auth"
proxy_connect_by_hostname = true
```

See the main repo's [OpenShell-Integration.md](
https://github.com/stevef/agent-gateway/blob/main/OpenShell-Integration.md)
for the full wiring and the `egress-demo.sh` demo for the call-by-call
walkthrough (smoke.sh checks the 407 posture on `:30088`).


## Storage (shared Gluster file system)

One `ReadWriteMany` PV on the cluster share (`/mnt/clustervol/k8s/agentgw`,
`storageClassName: gluster-shared`, `Retain`) backs the **live OPA policy**:
the console (playground) writes it and → within ~5 s — the authz engine on any
node re-reads it, with `opa check` validation and fail-safe reload. The
databases are intentionally **not** on the share — they use node-local
`hostPath` on the control-plane node. *Lab caveat:* a live Postgres on this
hobby-grade GlusterFS mount lost `pg_filenode.map` between processes; reliable
shared storage (EFS / Azure Files / Filestore-grade) may behave fine —
validate your filer's fsync/metadata consistency before putting a database
there, or use managed Postgres per the product Deployment Guide §6.1.

Note: this share root-squashes, so the console pod runs as root (squashed to
`nobody`, the file owner); on a volume without root-squash — or with
IAM-based access in the cloud — you can drop that `securityContext` override.

## Deploy

Build and validate the managed (`_m`) images in the private source repo, then
publish the multi-arch tags before asking the cluster to pull them:

```bash
cd /home/stevef/dev/agent-gateway
make image-m
# Validate the local managed images before publishing.
make push-m ALLOW_PUSH=yes
```

```bash
kubectl create ns agentgw
# From the private source checkout, issue a fresh managed licence.
cd /home/stevef/dev/agent-gateway
TMP_OUT=/tmp/managed-licences ./scripts/issue-managed-licence.sh agentgw -d 100
# From the private demo repo, apply the hosted key and generated licence as a Secret.
cd /home/stevef/dev/agent-gateway-demo
kubectl -n agentgw create secret generic agentgw-keys \
  --from-file=customer_private.pem=/home/stevef/dev/agent-gateway/keys/hosted/hosted_private.pem \
  --from-file=license.token=/tmp/managed-licences/agentgw/license.token \
  --dry-run=client -o yaml | kubectl apply -f -
```

Do **not** apply the public manifest while it still uses the demo Dex mock.
Configure the trusted OIDC issuer for authz, gateway and web, and create the
allowlist Secret from your verified operator address:

```bash
kubectl -n agentgw create secret generic agentgw-web-admin \
  --from-literal=emails='<verified-operator-email>'
```

Only after those prerequisites are ready, apply and watch the deployment:

```bash
kubectl apply -f k3s/agentgw.yaml
kubectl -n agentgw get pods -w
```

Tenant provisioning defaults to `MANAGED=1`. It requires the hosted private
key and issues a fresh vendor-signed licence; it will not silently fall back
to eval keys or eval images. Set `MANAGED=0` only for an explicitly chosen
evaluation deployment.

The managed images are encrypted to `keys/hosted/hosted_public.pem`; the
matching private key stays in the private source repo and is installed only
as the `agentgw-keys` Kubernetes Secret. Do not copy hosted key material into
the public demo repo.

After the real OIDC provider and managed images are deployed, open
`https://agw.sjfisher.com/`. Do not use the Dex mock/static credentials for a
public deployment.

## Running the console & demo UIs

Everything browser-facing is served by the `web` service:

| Surface | URL | What to try |
|---|---|---|
| Shared console | `https://agw.sjfisher.com/` | Public users sign in and decide only their own eligible CRM delete requests; the verified allowlisted operator also sees signup review |
| Guided demo | Disabled in the shared public profile | `DEMO_UI=0` |
| OPA playground | Disabled in the shared public profile | Policy administration stays private |

Notes:

* The copied **agent env** targets the gateway on `:30080` — that is why
  `PUBLIC_GATEWAY_URL` is set in the manifest (`:30083→:30080` cannot be
  guessed there).
* Playground edits persist in the shared volume; **Restore initial policy**
  (or re-seeding the volume) brings the committed default back.
* A stale tab after an upgrade: hard-refresh once. A leftover OIDC state
  cookie may show *"invalid oauth state"* once — click sign-in again.
* Headless/CLI check of the whole lifecycle:
  `bash k3s/smoke.sh` (defaults to `192.168.1.74`; pass another node IP as
  the first argument).
* **Protected-API demo** (approval-before-execution via the delegation's
  `approval_rules`, against the demoapi upstream): the same script works on
  both platforms — `demo/protected-api-demo.sh` (compose) or
  `demo/protected-api-demo.sh --node <ip>` (k3s; `make protected-api-k3s`).

## Public connector versus tenant administration

`https://agw.sjfisher.com` is the shared customer-connector demo. Ordinary
signed-in users can decide only their own pending `delete_customer` CRM
requests. The verified operator account can additionally review signup
requests; the API checks the configured email allowlist server-side.
Telegram, tenant administration and policy controls remain unavailable on
this shared console. The profile is configured on the web deployment with:

```yaml
- { name: WEB_PUBLIC_CONSOLE, value: "1" }
- { name: DEMO_UI, value: "0" }
```

With a web image that implements this profile, signed-in users can see and
decide only their own pending `delete_customer` CRM requests. Signup requests
remain public at `/signup.html`; only the verified, allowlisted operator can
see or decide them. The app has no password-change API; password and identity
administration belong to each tenant's own identity provider.

The manifest targets the managed web image and enables this profile, but it
must not be applied publicly until a real OIDC provider replaces the Dex
mock/static credentials and `agentgw-web-admin` contains the operator's
verified email. Create that Secret from the provider-verified address before
rollout. Never use the demo Dex mock as the public identity boundary. Expose
only the HTTPS ingress needed by Claude and the web console; firewall
NodePorts `30080`–`30083` from the public Internet.

```bash
kubectl -n agentgw create secret generic agentgw-web-admin \
  --from-literal=emails='<verified-operator-email>'
```

For an isolated tenant instance, configure `WEB_ADMIN_EMAILS` with that
tenant operator's email as verified by the tenant's OIDC provider. Only then
are signup review and tenant-scoped Telegram controls available in that
tenant's console. Keep each tenant's IdP/password lifecycle and Telegram
secret inside its own namespace; do not copy those settings into the shared
connector deployment.

## Rotate for anything real

`JWT_SECRET`, `GATEWAY_ADMIN_TOKEN`, `POSTGRES_PASSWORD` are demo-grade
values in `agentgw-secrets`; swap them before any shared use. The same goes
for Dex's static users/mock connector — production points
`OIDC_ISSUER_URL` at Okta/Entra/Keycloak instead (see docs in the product
`Deployment.md` §7.2).


## Telegram approval cards (tap-to-approve)

The gateway pushes a card per held action (buttons ✅ Approve / ❌ Deny).
The buttons deep-link to the console; the decision is made with YOUR verified
sign-in (a foreign human tapping the same card is refused). Values live in
the cluster only:

```bash
kubectl -n agentgw create secret generic agentgw-telegram \
  --from-literal=bot_token=<@BotFather token> \
  --from-literal=chat_id=<user or group id>
kubectl -n agentgw rollout restart deploy/gateway
```

(The manifest references this secret with `optional: true`, so the stack
runs normally with the channel disabled until you add it.)

## Tear-down and re-deploy

`kubectl delete ns agentgw` removes pods, services and the keys secret — but
the `ReadWriteMany` PV uses `Retain` (per the shared-Gluster pattern), so it
survives with a stale claimRef and **will not bind a recreated PVC** until it
is freed:

```bash
kubectl patch pv agentgw-shared-pv --type json \
  -p '[{"op":"remove","path":"/spec/claimRef"}]'
```

(`Retain` keeps the data on the share — the policy file persists, and
re-applying the manifest rebinds without re-seeding.)

* To also reset the databases, wipe `/srv/agentgw/postgres` and
  `/srv/agentgw/redis` on the control-plane node — or leave them: schema
  migrations are idempotent and the previous DB is reused.
* authz demands the policy file at start-up and may crash-loop briefly until
  web's init container has (re)seeded it; pod restarts absorb the ordering.

## Tenant DNS & Cluster CoreDNS

Preprod multi-tenancy routes tenants to `<name>.preprod.agw.sjfisher.com`.

### DNS Wildcards (Authoritative DNS)
Standard DNS wildcards (RFC 1034) do not cross dot boundaries. The authoritative DNS requires:
* `*.agw.sjfisher.com -> k3s.sjfisher.com` (covers 1st-level subdomains)
* `*.preprod.agw.sjfisher.com -> k3s.sjfisher.com` (covers 2nd-level tenant preprod subdomains)

### Cluster CoreDNS Upstream Forwarder (`coredns-custom.yaml`)
To prevent internal pod OIDC discovery and cert-manager ACME checks from failing when local routers cache negative NXDOMAIN responses, CoreDNS is configured via `k3s/coredns-custom.yaml` to forward `agw.sjfisher.com` directly to public upstream resolvers (`1.1.1.1` and `8.8.8.8`). `add-tenant.sh` automatically ensures this ConfigMap is applied.

## Endpoint & Tenant Availability Monitor (`endpoint-monitor.yaml`)

A lightweight, zero-maintenance Kubernetes CronJob running every 30 minutes (`*/30 * * * *`) that probes all public endpoints on the cluster and alerts you via Telegram if any endpoint goes down, with recovery notifications when it returns to healthy.

### Features
* **Dynamic Tenant Discovery**: Reads all hostnames across all cluster `Ingress` objects (`agw.sjfisher.com`, `preprod.agw.sjfisher.com`, `testten1.preprod.agw.sjfisher.com`, `me.sjfisher.com`, plus any future tenants created by `add-tenant.sh`).
* **Smart Probing**: Checks `/healthz` (falling back to `/` for personal/avatar apps like `me.sjfisher.com`).
* **State-Aware (No Alert Spam)**: Maintains previous failure state in ConfigMap `endpoint-monitor-state`. Only alerts on state changes (new failure 🚨, or recovery ✅).
* **Zero Custom Image**: Uses standard `curlimages/curl:latest` and existing `agentgw-telegram` secret.

### Deploy & Test
```bash
# Deploy to cluster
kubectl apply -f k3s/endpoint-monitor.yaml

# Run an immediate manual check
kubectl create job --from=cronjob/endpoint-monitor endpoint-monitor-test -n tenant-preprod
kubectl logs -n tenant-preprod job/endpoint-monitor-test -f
```



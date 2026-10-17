# Agent Gateway on k3s

Deploy the full stack (authz, tokensvc, gateway, console, Dex IdP, Postgres,
Redis) into the `agentgw` namespace.

## Layout

| Service | Image | Exposure |
|---|---|---|
| web (console + playground) | `agent-gateway-web:1.0.28` | NodePort **30083** |
| gateway (enforcement) | `agent-gateway-gateway:1.0.22` | NodePort **30080** + **30088** (egress proxy) |
| authz (decision point) | `agent-gateway-authz:1.0.12` | NodePort **30081** |
| tokensvc (minting) | `agent-gateway-tokensvc:1.0.5` | NodePort **30082** |
| dex (local OIDC IdP) | `dexidp/dex:v2.41.1` | ClusterIP only (browser traffic is proxied via `/oidc/idp/…`) |
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

```bash
kubectl create ns agentgw
# licence material (from the demo repo's demo/keys)
cd agent-gateway-demo/demo/keys
kubectl -n agentgw create secret generic agentgw-keys \
  --from-file=customer_private.pem=customer_private.pem \
  --from-file=license.token=license.token
cd -
kubectl apply -f k3s/agentgw.yaml
kubectl -n agentgw get pods -w
```

Then open `http://<node>:30083` (Dex mock connector → one-click sign-in;
the OIDC redirect whitelist already contains `http://192.168.1.74:30083/...`
— update `dex-config` if you expose it elsewhere).

## Running the console & demo UIs

Everything browser-facing is served by the `web` service:

| Surface | URL | What to try |
|---|---|---|
| Admin console | `http://<node>:30083/` | Sign in with Dex (one click, mock connector) · create a delegation and copy the agent env · watch the **Approvals** heading show a red pending badge + toast when a held action appears · approve only as the signed-in delegating user (the gateway refuses anyone else) |
| Guided demo | `http://<node>:30083/demo.html` | The nine-step walkthrough: SSO → delegation → mint → allow → hold → approve → retry → revoke → deny. Step 1 auto-resumes after the SSO redirect |
| OPA playground | `http://<node>:30083/policy.html` | Run the probes, edit the `spend_breached` cap, **Apply** and watch the €250 probe flip within ~5 s — the engine re-reads the policy from the cluster-shared volume, so the edit and the engine may be on **different nodes**. **Restore initial policy** reverts |

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

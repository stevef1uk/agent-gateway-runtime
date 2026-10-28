# How Agents Get a JWT — A Beginner's Guide

This page explains, in plain terms, the credential dance an AI agent
performs before it can talk to **Agent Gateway** (the tool gateway) or to
the gateway's **egress proxy** (used with NVIDIA OpenShell sandboxes). If
you already know the system, see [Architecture.md](Architecture.md) for
the deeper story.

## The four players

| Player | Port | Role in the story |
|---|---|---|
| **authz** | 8081 | Keeps the *delegations*. When a human grants permission, this service issues the two credentials the agent will use. |
| **tokensvc** | 8082 | The *mint*. Takes the two credentials for a short-lived JWT. |
| **gateway** | 8080 | The *tool gateway* (policy enforcement point). Every tool call must present the JWT here. |
| **gateway (proxy mode)** | 8088 | The *egress proxy*. Outbound traffic from OpenShell sandboxes passes through here, authenticated with the same kind of JWT. |

## The two credentials an agent receives

When the human grants a delegation (`POST /v1/delegations` on authz,
usually via the web console or a setup script), authz answers with **three**
things:

```json
{
  "delegation":   { "id": "del-abc123", "...": "..." },
  "token":        "eyJhbGciOi...",   // a ready-to-use JWT (see below)
  "agent_secret": "sec-9f3e..."      // the agent's own secret
}
```

- **`delegation_id`** (`del-abc123`) — identifies the grant. It is *not*
  secret by itself; you need something else to prove you are allowed to
  use it.
- **`agent_secret`** (`sec-9f3e...`) — the per-delegation secret. This is
  the credential you hand to the agent's operator/process once, at
  delegation time. authz stores only a hash, so nobody (not even the
  database) can reuse it.
- **`token`** — authz also mints one JWT immediately for convenience,
  but it has a short life. For anything longer, re-mint via tokensvc.

**Rule of thumb:** `delegation_id` + `agent_secret` are the *keys to the
mint*. The JWT is the *pass you carry* to the gateway.

### Where the ID token comes from (human side)

Before a delegation can be created on a tenant with SSO enabled, the
human (delegating user) must prove who they are with an OIDC ID token.
`POST /v1/delegations` on authz requires `"id_token": "<jwt>"`; authz
verifies it against the tenant's IdP (JWKS) and binds the delegation to
the token's `sub` claim.

On the local demo stack this happens automatically through Dex (the mock
connector needs no credentials), which is why `demo.sh` and
`kill-switch-demo.sh` sign you in transparently. On a remote tenant
(preprod, k3s, cloud) you obtain it yourself:

| Method | How |
|--------|-----|
| **Console session** | Sign in at the tenant console, open DevTools → Network, find the `POST` to the token endpoint (`/dex/token`, `/oauth/token`, …) whose response JSON contains `id_token`. Copy that JWT. |
| **OIDC auth-code flow** | Complete the authorization-code flow against the tenant's IdP and exchange the code for an ID token (see *Obtaining an ID token for a remote tenant* in [Demos.md](Demos.md)). |

Once you have the ID token, pass it in the delegation body (`"id_token"`) — or as `--id-token` / `ID_TOKEN=` when using `kill-switch-remote.sh` — and the delegation is bound to your verified subject. Any later call made with a delegation-scoped JWT is re-authorized against that subject's grant.

## How the agent obtains a JWT

One HTTP call to the token service:

```bash
curl -s -X POST http://127.0.0.1:8082/token \
  -H 'Content-Type: application/json' \
  -d '{
    "delegation_id": "del-abc123",
    "agent_secret":  "sec-9f3e...",
    "ttl_seconds":   600
  }'
```

Response:

```json
{
  "access_token": "eyJhbGciOiJIUzI1NiJ9...",
  "token_type": "Bearer",
  "expires_in": 600,
  "delegation_id": "del-abc123"
}
```

What the token service does behind the scenes:

1. Looks up the delegation at authz; refuses when revoked or expired.
2. Verifies the `agent_secret` against the stored hash.
3. Mints a JWT signed with the shared `JWT_SECRET`, carrying
   `agent_id`, `user_id`, `delegation_id`, and the audience.
   Default TTL if you omit `ttl_seconds` is 5 minutes.

Frequent minting is normal and encouraged — the JWT is deliberately
short-lived. Re-mint whenever it expires (deal with 401 by minting a new
token, not by storing long-lived ones).

## Using the JWT against the tool gateway (:8080)

Attach the token on every call:

```bash
curl -s -X POST http://127.0.0.1:8080/v1/tools/... \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'X-Agent-Tool: purchase' \
  -H 'X-Agent-Resource: payments' \
  -H 'X-Agent-Action: create' \
  -d '{...}'
```

The gateway then resolves the token, checks revocation, and asks authz
for a per-call decision:

- **Allow** → forwarded to the upstream service, audited.
- **Approval required** → you get `202` + `approval_id`; a human must
  approve (web console / Telegram / webhook) before the call proceeds.
- **Deny** → `403` + reason, audited.

Any language works — it is plain HTTP: POST to `:8082/token` for the
mint, then the request above with the Bearer header. Wire a re-mint on
the next `401` and you have the whole client.

## OpenShell sandboxes and the egress proxy (:8088)

The OpenShell case works differently on the surface, but it is **the
same credential and the same mint**. OpenShell's supervisor can only
present a classic HTTP-proxy Basic password — it cannot mint tokens. So
you mint the token elsewhere and give it to the supervisor as the
*username* of one Basic credential:

1. **Create a delegation** allowing (for example) OpenRouter traffic,
   and hold dangerous actions (`connect`, `delete`) for human approval.
2. **Mint a token** from delegations as above.
3. **Write it as Basic credentials** into the OpenShell upstream-proxy
   auth file (token as username, anything as password):

   ```bash
   printf '%s:x\n' "$AGENT_TOKEN" > ~/.config/openshell/upstream-proxy-auth
   chmod 600 ~/.config/openshell/upstream-proxy-auth
   ```

4. Point the OpenShell gateway at the Agent Gateway egress proxy
   (`https_proxy = "http://127.0.0.1:8088"` and `proxy_auth_file = ...`
   in `~/.config/openshell/gateway.toml`).

The supervisor then sends `Proxy-Authorization: Basic <token>:x` on each
proxied request; the gateway decodes the username back into your token,
verifies it like a Bearer token, and makes the same allow/approve/deny
decision per destination host.

Basic-auth is **opt-in and source-scoped**; on the gateway you must
enable it:

```bash
PROXY_BASIC_AUTH=1
PROXY_BASIC_AUTH_CIDRS="127.0.0.0/8,::1/128"   # loopback by default
```

A Basic request from a non-allowed source is rejected with `407` before
the token is even looked at. Callers using `Authorization: Bearer` are
unaffected. Full wiring instructions are in
[OpenClaw-OpenShell.md](OpenClaw-OpenShell.md).

## Things that commonly trip people up

| Symptom | Likely cause |
|---|---|
| `403 agent secret invalid` from tokensvc | The `agent_secret` you present does not match the one issued when the delegation was created (secrets are issued once and never shown again). |
| `403 delegation has no agent secret on file` | Old/dev delegation without a secret. Re-create the delegation, or opt into dev-only minting with `TOKENSVC_ALLOW_NO_SECRET_MINT=1` (never in production). |
| `403 delegation revoked` / `expired` | The delegation was revoked or passed its expiry; ask the human to create a new one. |
| `401` on token validation somewhere | Every service that validates tokens (authz, tokensvc, gateway) must run with the **same `JWT_SECRET`**; if one differs, signatures fail. |
| `407` from the egress proxy | Proxy Basic auth is not enabled, your source IP is not in `PROXY_BASIC_AUTH_CIDRS`, or the token in `upstream-proxy-auth` is stale. |
| Token expires mid-session | Expected — mint a fresh one. Tokens re-mint while the delegation is alive; revoking the delegation kills all future mints. |

## One-paragraph summary

A human grants a **delegation**; that grants the agent its two
credentials (`delegation_id` + `agent_secret`). The agent trades them at
**tokensvc** for a short-lived **JWT**. It uses that JWT to call the
**tool gateway** (`Authorization: Bearer ...`) or to authenticate at the
**egress proxy** (Basic username = token, for OpenShell supervisors).
Every single call is independently re-authorized against the
delegation: allowed, held for human approval, or denied.

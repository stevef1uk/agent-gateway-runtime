# Put the Go proxy between an existing API consumer and its upstream API

Use Agent Gateway's **Go egress forward proxy** to add delegated access,
destination restrictions, optional human approval, and audit records to an
existing API consumer. The consumer can be a script, service, SDK-based
application, or agent; OpenShell and OpenClaw are not required.

The consumer keeps calling its existing upstream URL. You configure its HTTP
transport to send traffic through the proxy and supply a delegation token.
The upstream API needs no gateway-specific changes.

## 1. Choose the integration shape

```text
Before:
API consumer ----------------------------------------> upstream API

Explicit forward proxy:
API consumer --> Agent Gateway Go proxy :8088 --------> upstream API
                 | token validation / authorization
                 | approval gate / audit

With the optional local credential helper:
API consumer --> Go helper :8888 --> gateway :8088 ----> upstream API
                 | token minting      | enforcement
                 | and caching
```

There are two Go components:

| Component | Configuration | Responsibility |
|---|---|---|
| Gateway egress proxy | `GATEWAY_PROXY_ADDR` on the gateway container | Validates proxy credentials, authorizes destinations, gates approvals, and forwards traffic |
| [`demo/connect-proxy.go`](../demo/connect-proxy.go) | Command-line arguments; listens on `:8888` | Obtains and caches a token, attaches Bearer proxy authentication, and forwards to the gateway |

Use the gateway directly if your client can set `Proxy-Authorization`. Use the
helper for HTTPS consumers that support a proxy URL but cannot conveniently
mint tokens or attach a Bearer proxy header.

### What can be governed?

For **HTTPS**, the consumer sends `CONNECT api.example.com:443`. The gateway
authorizes that destination and, when allowed, opens a tunnel. TLS remains
end to end between the consumer and the upstream API: the proxy cannot see
the URL path, HTTP method, request body, or upstream credentials inside it.

Consequently, a delegation permitting `connect` to an HTTPS host permits a
tunnel to that host, rather than distinguishing `GET /orders` from
`DELETE /orders/123`. A persistent tunnel may carry multiple API calls;
authorization and approval are at tunnel establishment, not at each encrypted
request. Revocation prevents subsequent authorizations; do not assume it
terminates an already-open tunnel.

For **plain HTTP**, the gateway can authorize each HTTP request using its
destination and the method-derived action, such as `GET` → `read`.

If you need path-, payload-, or individual-operation enforcement for an HTTPS
API, use the gateway's **reverse-proxy listener** instead: point the consumer
at the gateway and configure `UPSTREAM_URL` for the real API. See
[Protecting Your API](Protecting-Your-API.md) and
[Integration Patterns](Integration-Patterns.md). The forward-proxy setup below
does not use `UPSTREAM_URL` to select destinations.

## 2. Start the gateway with proxy mode enabled

For the local demo, follow the repository's [setup instructions](../README.md)
for Docker/Podman and the demo keys/licence. Then, **from `demo/`**, run:

```bash
docker compose -f docker-compose.yml -f docker-compose.egress.yml up -d
```

The base Compose file publishes `8088:8088`; the overlay enables the listener.
Publishing the port alone does not start the proxy.

| Setting | Purpose |
|---|---|
| `GATEWAY_PROXY_ADDR=0.0.0.0:8088` | Start the forward-proxy listener |
| `AUTHZ_URL` | Authorization/delegation service; locally `http://authz:8081` |
| `JWT_SECRET`, `JWT_ISSUER` | Token validation; must match the token issuer |
| `REDIS_URL` | Token-revocation storage |
| `PERSISTENCE`, `DATABASE_URL` | Persistence configuration |
| `APPROVAL_CONSOLE_URL` | Console URL linked from approval notifications |

The supplied Compose files configure these dependencies. Keep the existing
stack settings when enabling the proxy. For a deployment beyond the demo,
see the [Deployment Guide](Deployment-Guide.md).

All URLs below assume the consumer runs on the Docker host. From another
container, use an address reachable from that container, such as the Compose
service name `gateway:8088` on the same network. `127.0.0.1` always refers to
the caller's own network namespace.

## 3. Delegate access to the upstream host

The following commands run from the **repository root**, in the same shell.
They require `curl` and `jq`. First obtain the delegating human's OIDC ID
token; the local demo's Dex mock connector is supported by:

```bash
export ID_TOKEN="$(./demo/obtain-id-token.sh)"
```

For another tenant, use that tenant's IdP settings with the script, or obtain
the ID token through its OIDC sign-in flow. See
[Agent Auth Basics](Agent-Auth-Basics.md#where-the-id-token-comes-from-human-side).
The human's ID token is used to establish the delegation; it is not the
credential sent to the proxy.

This HTTPS example grants access to one host for 30 minutes. Replace
`api.example.com` with the upstream API's hostname, **without a scheme or
URL path**. For a public connectivity smoke test, use `example.com` and
`https://example.com/` in the later request examples.

```bash
export AUTHZ_URL=http://localhost:8081
export TOKENSVC_URL=http://localhost:8082/token
export PROXY_URL=http://localhost:8088
export API_HOST=api.example.com

DELEGATION=$(jq -n \
  --arg id_token "$ID_TOKEN" \
  --arg host "$API_HOST" \
  '{agent_id:"existing-api-consumer", resources:[$host],
    actions:["connect"], expires_in_seconds:1800, id_token:$id_token}' \
  | curl --fail-with-body -sS "$AUTHZ_URL/v1/delegations/" \
      -H 'Content-Type: application/json' --data-binary @-)

export DELEGATION_ID=$(jq -er '.delegation.id' <<< "$DELEGATION")
export AGENT_SECRET=$(jq -er '.agent_secret' <<< "$DELEGATION")
```

Retain the returned agent secret in the consumer's secret store. It is the
credential used to mint replacement tokens. Give separate consumers separate
delegations when they need distinct scopes, audit identities, or revocation.

For plain HTTP reads, include `read` in `actions`; for a consumer needing
both HTTP reads and HTTPS tunnels, use `["read","connect"]` as in
[`demo/egress-demo.sh`](../demo/egress-demo.sh). Additional destinations,
including redirect targets, need their own delegated resources.

## 4. Mint the proxy credential

```bash
TOKEN_RESPONSE=$(jq -n \
  --arg delegation_id "$DELEGATION_ID" \
  --arg agent_secret "$AGENT_SECRET" \
  '{delegation_id:$delegation_id, agent_secret:$agent_secret, ttl_seconds:600}' \
  | curl --fail-with-body -sS "$TOKENSVC_URL" \
      -H 'Content-Type: application/json' --data-binary @-)

export AGENT_TOKEN=$(jq -er '.access_token // .token' <<< "$TOKEN_RESPONSE")
```

The token is short-lived. Direct integrations should renew before the issued
token expires and update their proxy credential. Renewal cannot extend an
expired or revoked delegation.

Keep the two authentication layers distinct:

| Header | Credential | Recipient |
|---|---|---|
| `Proxy-Authorization: Bearer …` | Agent Gateway delegation token | Gateway proxy |
| `Authorization: Bearer …` (or the API's normal header) | Existing upstream API credential | Upstream API |

The proxy token does not replace the API's existing key or OAuth token.
For HTTPS, upstream authentication travels inside the encrypted tunnel.

## 5. Connect the existing consumer

### Direct: a client that supports Bearer proxy headers

This curl example preserves the upstream URL and its authentication:

```bash
export UPSTREAM_URL="https://$API_HOST/v1/orders"
export UPSTREAM_API_TOKEN='<your existing upstream API token>'

curl --fail-with-body --show-error --noproxy '' \
  --proxy "$PROXY_URL" \
  --proxy-header "Proxy-Authorization: Bearer $AGENT_TOKEN" \
  -H "Authorization: Bearer $UPSTREAM_API_TOKEN" \
  "$UPSTREAM_URL"
```

`--noproxy ''` prevents a local `NO_PROXY` setting from bypassing this example.
Use the client's proxy-header API: for HTTPS, adding `Proxy-Authorization` as
an ordinary origin header is not equivalent to attaching it to CONNECT.

### Helper: a client that only needs a proxy URL

Build just the helper source file, **from the repository root**:

```bash
go build -o /tmp/connect-proxy ./demo/connect-proxy.go

/tmp/connect-proxy \
  "$PROXY_URL" "$TOKENSVC_URL" "$DELEGATION_ID" "$AGENT_SECRET"
```

Leave it running. In a second terminal, configure the existing consumer:

```bash
HTTPS_PROXY=http://127.0.0.1:8888 NO_PROXY= curl \
  -H "Authorization: Bearer $UPSTREAM_API_TOKEN" \
  "https://$API_HOST/v1/orders"
```

Set `API_HOST` and `UPSTREAM_API_TOKEN` in that terminal too. Other consumers
can use the same proxy URL in their HTTP transport or SDK configuration.
For Node.js versions supporting environment proxies, launch with
`HTTPS_PROXY=http://127.0.0.1:8888 NODE_USE_ENV_PROXY=1`; verify that the SDK's
chosen HTTP transport honors those settings. Proxy environment variables are
client-dependent, not universal network interception.

The helper's current behaviour is defined in
[`connect-proxy.go`](../demo/connect-proxy.go):

- It listens on **all interfaces at `:8888`**, with no local client
  authentication. Deploy it within the consumer's trusted network boundary.
- It requests a 600-second token at startup and checks a fixed five-minute
  cache interval when a request needs a token. This is request-triggered
  renewal, not a background expiry-aware scheduler.
- On a token-fetch failure it retains the previous token. It also attempts
  one CONNECT retry on `401`/`407`, but the refresh routine still applies the
  five-minute cache guard; do not rely on that retry to force a new token.
- Its gateway hop uses plain TCP to an HTTP proxy. Use an `http://host:port`
  gateway URL; passing `https://` does not add TLS to that hop.
- An optional fifth argument, `[parent-proxy-url]`, chains the gateway
  connection through a parent HTTP proxy and routes token minting through
  that parent too. Omit it for a normal direct setup.

This helper recipe targets HTTPS CONNECT traffic. For plain HTTP consumers,
use a direct proxy-capable transport; the helper's plain-HTTP relay is not
equivalent to a full production HTTP proxy.

### Basic-auth-only proxy clients

The gateway also supports token-as-username Basic proxy authentication when
explicitly enabled with `PROXY_BASIC_AUTH=1` and allowed by
`PROXY_BASIC_AUTH_CIDRS`. The demo egress overlay enables it for OpenShell
compatibility; direct Bearer clients do not require it. See
[the Basic authentication configuration](OpenClaw-OpenShell.md#why-basic-auth--and-how-it-is-kept-safe)
for the credential format and source-address restrictions.

## 6. Add human approval when required

First establish connectivity without an approval rule. Then add this field
to the delegation-creation JSON when human approval is part of the use case:

```json
"approval_rules": [
  {
    "when": {"resource_pattern": "*"},
    "require": true,
    "rationale": "Human approval required before opening an upstream connection"
  }
]
```

For HTTPS this gates CONNECT, not individual operations inside the tunnel.
A held request returns `202` with approval information; the consumer must
retry after the human approves in the console. Approval does not itself
resume the original failed client connection. Denied or expired approvals
must be handled as such rather than retried indefinitely.

Many HTTP libraries, including curl, report a non-200 CONNECT response as a
tunnel failure and hide the JSON approval body. The local helper does not
implement an approval UI or polling loop. An integration needing this flow
must surface the hold to the operator or use the console/notifications and
retry after approval. [Demo 5](Demos.md#demo-5--all-outbound-egress-via-the-gateway-approved-per-call-demoegress-demosh)
and [`egress-demo.sh`](../demo/egress-demo.sh) demonstrate raw CONNECT response
inspection and the approve/retry sequence.

## 7. Verify the insertion

Use a public, reachable test host allowed by the deployment's egress policy:

1. **No proxy credential:** make a direct request through `:8088` without
   `Proxy-Authorization`. Expect `407`, with no upstream connection.
2. **Allowed destination:** use the token and delegated host. Expect the
   normal upstream response (or an upstream `401` if its own credential is
   missing), and a corresponding gateway audit decision.
3. **Undelegated destination:** request a different public host using the
   same token. Expect policy denial, normally `403`; an HTTPS client may
   display it as a CONNECT failure.
4. **Revocation:** revoke the delegation in the console and open a new
   connection. It should be denied even if its JWT has not expired.
5. **Approval, if configured:** confirm a new connection is held, approve it
   in the console, and retry. Confirm the hold and decision in the audit view.

Inspect gateway logs with:

```bash
docker compose -f docker-compose.yml -f docker-compose.egress.yml logs gateway
```

Run that command from `demo/`. Internal/private destinations may additionally
be blocked by the gateway's SSRF/egress protections; a delegation alone does
not guarantee that every destination is connectable.

| Symptom | Check |
|---|---|
| Connection refused on `8088` | Overlay enabled, listener configured, port published, correct network address |
| `407` | Proxy header attached to CONNECT; token present/current; Basic mode and source CIDR if using Basic |
| `403` | Delegation host/action, expiry/revocation, deployment policy, and destination restrictions |
| CONNECT failure with approval enabled | Inspect the console for a pending hold; client may hide the `202` body |
| Upstream `401`/`403` after tunnel establishment | The upstream API's own credentials and permissions |
| No gateway audit decision | SDK ignored the proxy, `NO_PROXY` bypassed it, or an existing tunnel was reused |

## Deployment boundaries

The explicit proxy governs traffic sent to it. If consumers must be unable
to bypass it, enforce that at the network/sandbox layer and account for
`NO_PROXY`, redirects, and any transports that ignore proxy configuration.
The gateway itself needs network access to the upstream destinations.

The localhost examples use an HTTP proxy hop. HTTPS still protects the
consumer-to-upstream payload, but it does not encrypt the proxy's own CONNECT
credential on that hop. For a remote proxy, use a TLS-protected ingress with
a compatible direct client, or a protected network/tunnel; the supplied Go
helper does not implement TLS to the gateway.

For a browser frontend that must not hold delegation secrets, put a
server-side backend-for-frontend in front of the gateway. The Go web-proxy
example in [Integration Patterns, Pattern E](Integration-Patterns.md#pattern-e--public-web-frontends--backend-proxy-bff)
is a separate application-specific adapter, rather than the CONNECT helper
documented here.

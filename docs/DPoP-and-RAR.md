# DPoP (RFC 9449) and Rich Authorization Requests (RFC 9396)

Agent Gateway supports **DPoP (Demonstrating Proof of Possession at the Application Layer)** and **RAR (Rich Authorization Requests)** natively across the token service (`tokensvc`) and policy enforcement point (`gateway`).

Both standards operate alongside existing Bearer tokens with **100% backward compatibility**.

---

## 1. Why DPoP & RAR for AI Agents?

Standard OAuth Bearer tokens operate like cash: whoever holds the token string can present it to perform actions. In agentic architectures, bearer tokens create significant risk:
- **Token exfiltration**: Agent scratchpads, prompt traces, verbose MCP logs, or compromised worker processes can expose access tokens.
- **Over-privileged tokens**: Coarse scopes (e.g. `mcp`, `read`, `write`) grant far more authority than an agent needs for an individual sub-task.

Agent Gateway resolves both threats:
1. **DPoP (RFC 9449)** binds the access token cryptographically to an asymmetric private key held by the agent runtime. Stealing the token string is useless without the private key.
2. **RAR (RFC 9396)** lets agents downscope short-lived tokens to fine-grained action lists, resource paths, and numerical limits (e.g. spend caps) for a specific sub-task.

```
       Client / Agent                        Token Service                    Gateway PEP
       (holds private key)                   (:8082)                          (:8080)
              │                                   │                              │
              │  1. POST /token                   │                              │
              │     DPoP: <proof_jwt (no ath)>    │                              │
              │     auth_details: [read /orders]  │                              │
              │ ─────────────────────────────────>│                              │
              │                                   │                              │
              │  2. Token response                │                              │
              │     token_type: "DPoP"            │                              │
              │     access_token: {cnf, rar}      │                              │
              │ <─────────────────────────────────│                              │
              │                                                                  │
              │  3. GET /orders                                                  │
              │     Authorization: DPoP <token>                                  │
              │     DPoP: <proof_jwt (with ath)>                                 │
              │ ────────────────────────────────────────────────────────────────>│
              │                                                                  │
              │                                     [Validate proof signature]   │
              │                                     [Verify jkt matches cnf.jkt] │
              │                                     [Verify ath matches token]   │
              │                                     [Check jti replay cache]     │
              │                                     [Enforce RAR permissions]    │
              │                                     [Evaluate delegation policy] │
              │                                                                  │
              │  4. HTTP 200 OK (Action Executed)                                │
              │ <────────────────────────────────────────────────────────────────│
```

---

## 2. DPoP Implementation (RFC 9449)

### Key Generation & Proof Structure
The agent maintains an asymmetric key pair (e.g. `ES256`, `RS256`, or `EdDSA`). For each request, the agent generates an ephemeral signed JWT proof:

```json
{
  "typ": "dpop+jwt",
  "alg": "ES256",
  "jwk": {
    "kty": "EC",
    "crv": "P-256",
    "x": "...",
    "y": "..."
  }
}
.
{
  "jti": "random-unique-id",
  "htm": "POST",
  "htu": "http://localhost:8080/orders",
  "iat": 1729929600,
  "ath": "fUHyO2r2Z3DZ53EsNrWBb0xWXoaNy59IiKNPEDmKOI0"
}
```

- **`htm` / `htu`**: The HTTP method and target URI without query parameters or fragments.
- **`ath`**: Access Token Hash (`base64url(sha256(access_token))`). Required when presenting tokens to the gateway; omitted when minting at `/token`.
- **`jti`**: Unique proof identifier. The gateway maintains a thread-safe replay cache to reject replayed proofs.

### Minting a DPoP Token
Send `POST /token` or `POST /token/exchange` with the `DPoP` header:

```bash
curl -X POST http://localhost:8082/token \
  -H "Content-Type: application/json" \
  -H "DPoP: <proof_jwt>" \
  -d '{
    "delegation_id": "del-642d4dde0439aedf43c0dc5b",
    "agent_secret": "sec-...",
    "ttl_seconds": 300
  }'
```

Response:
```json
{
  "access_token": "eyJhbGciOi...",
  "token_type": "DPoP",
  "expires_in": 300,
  "delegation_id": "del-642d4dde0439aedf43c0dc5b"
}
```

The issued token contains an RFC 7800 / RFC 9449 confirmation claim:
```json
{
  "cnf": {
    "jkt": "0Z9Xq_w... (RFC 7638 SHA-256 JWK thumbprint)"
  }
}
```

### Presenting to the Gateway
Present the token using the `DPoP` authentication scheme and provide a fresh proof:

```bash
curl -X POST http://localhost:8080/orders \
  -H "Authorization: DPoP <access_token>" \
  -H "DPoP: <proof_jwt_with_ath>" \
  -H "Content-Type: application/json" \
  -d '{"order_id": "ord-1", "amount": 50}'
```

### Strict Security Enforcement
- **Scheme Enforcement**: Presenting a DPoP-bound token with `Authorization: Bearer <token>` returns `401 Unauthorized`.
- **Bearer Protection**: Presenting a standard Bearer token under `Authorization: DPoP <token>` returns `401 Unauthorized`.
- **Replay Protection**: Presenting a duplicate `jti` proof returns `401 Unauthorized`.
- **Key Binding**: Presenting a proof signed by any key other than the one matching `cnf.jkt` returns `401 Unauthorized`.

---

## 3. Rich Authorization Requests (RFC 9396)

RAR allows callers to specify structured, fine-grained requirements during token minting and token exchange.

### Requesting Downscoped Details
An agent holding authority over `/orders/*` and `/suppliers/*` can downscope an ephemeral token to **read-only access on `/orders`**:

```bash
curl -X POST http://localhost:8082/token \
  -H "Content-Type: application/json" \
  -d '{
    "delegation_id": "del-642d4dde0439aedf43c0dc5b",
    "agent_secret": "sec-...",
    "ttl_seconds": 300,
    "authorization_details": [
      {
        "type": "agent_gateway",
        "resources": ["/orders"],
        "actions": ["read"],
        "limits": {
          "spend_per_order": { "type": "currency", "max": 100, "unit": "EUR" }
        }
      }
    ]
  }'
```

### Downscoping Validation
The token service validates that requested authorization details are a strict subset of the underlying human delegation:
- If an agent requests an action or resource outside its delegation (e.g. `delete` or `/finance/*`), the request is refused with `400 Bad Request` (`invalid_authorization_details`).
- If an agent requests a higher limit than the delegation permits (e.g. €500 when the delegation permits €200), the request is refused with `400 Bad Request`.

### Gateway PEP Enforcement
When the gateway receives a request carrying `authorization_details`:
1. It verifies that the invoked action and resource match the token's granted details.
   - Invoking `GET /orders` succeeds (`200 OK`).
   - Invoking `POST /orders` (action `create`) is denied (`403 Forbidden`).
   - Invoking `GET /suppliers` is denied (`403 Forbidden`).
2. It verifies that parameters in the call context do not exceed granted limits.
3. It evaluates underlying delegation policies (e.g. auto-approve thresholds, human-in-the-loop approval holds).

---

## 4. Combined DPoP + RAR

DPoP and RAR are fully composable. A single token can be both **sender-constrained** and **downscoped**:

```bash
curl -X POST http://localhost:8082/token \
  -H "Content-Type: application/json" \
  -H "DPoP: <dpop_proof_without_ath>" \
  -d '{
    "delegation_id": "del-...",
    "agent_secret": "sec-...",
    "ttl_seconds": 300,
    "authorization_details": [{
      "type": "agent_gateway",
      "resources": ["/orders"],
      "actions": ["read"]
    }]
  }'
```

Response:
```json
{
  "access_token": "eyJhbGciOi...",
  "token_type": "DPoP",
  "expires_in": 300,
  "delegation_id": "del-...",
  "authorization_details": [
    {
      "type": "agent_gateway",
      "resources": ["/orders"],
      "actions": ["read"]
    }
  ]
}
```

Presenting this token requires:
- `Authorization: DPoP <token>`
- `DPoP: <proof_jwt_with_ath>`
- Executing only actions permitted by `authorization_details`

---

## 5. Metadata Discovery

The gateway's OAuth discovery endpoints (`/.well-known/oauth-authorization-server`) advertise DPoP algorithms and RAR detail types:

```json
{
  "issuer": "https://gateway.example.com",
  "dpop_signing_alg_values_supported": ["ES256", "RS256", "EdDSA"],
  "authorization_details_types_supported": ["agent_gateway", "mcp"],
  "response_types_supported": ["code"],
  "grant_types_supported": ["authorization_code", "refresh_token"],
  "code_challenge_methods_supported": ["S256"]
}
```

---

## 6. Full Backwards Compatibility

No changes are required for existing integrations:
- Requests to `/token` without `DPoP` or `authorization_details` issue standard `Bearer` tokens.
- Requests to the gateway with `Authorization: Bearer <token>` continue to be validated against delegation policies as usual.
- MCP connectors (Claude, Cursor, Inspector) continue operating unchanged.

---

## 7. Running Tests & Live Verification

### Automated Live Scripted Demo
With the demo stack running (`docker compose up -d`), run:
```bash
./demo/dpop-rar-demo.sh
```
This script exercises the full lifecycle against the live stack:
1. Authenticates via Dex SSO
2. Creates a human delegation with spend limits
3. Generates an asymmetric EC key pair and mints an RFC 9449 DPoP token
4. Verifies stolen DPoP tokens presented as `Bearer` are rejected (HTTP 401)
5. Verifies valid DPoP presentations are accepted (HTTP 200)
6. Verifies replayed proof attempts are rejected (HTTP 401)
7. Mints an RFC 9396 RAR downscoped token (`["read"]` only)
8. Verifies RAR policy enforcement (`read` allowed, `create` denied with HTTP 403)
9. Executes combined DPoP + RAR sender-constrained downscoped call

### Source Test Suite (in `agent-gateway`)
```bash
# Unit tests
go test -v ./internal/auth/dpop/...
go test -v ./internal/auth/rar/...
go test -v ./internal/tokensvc -run "DPoP|RAR"
go test -v ./internal/gateway -run "DPoP|RAR"

# End-to-end integration test against running compose stack
go test -v -count=1 ./test/ -run TestLiveDPoPAndRAREndToEnd
```

# Security Policy

Agent Gateway is designed to provide identity verification, zero-trust authorization, cryptographic proof-of-possession, and policy enforcement for autonomous AI agents acting on behalf of humans.

We take the security of our platform seriously. We welcome security researchers, auditors, and practitioners to review the architecture and report any vulnerabilities responsibly.

---

## Reporting a Vulnerability

If you discover a security vulnerability in Agent Gateway, please report it via private email:

- **Primary Contact**: `steve@sjfisher.com`
- **Response Target**: Within 48 hours with acknowledgment and initial triage.

**Please do not open public GitHub issues or public discussions for undisclosed vulnerabilities.**

When reporting, please include:
1. Description of the vulnerability and its potential impact.
2. Step-by-step reproduction instructions or a minimal proof of concept (PoC).
3. The affected component (`authz`, `tokensvc`, `gateway`, `web`, or client SDK).
4. Any proposed remediations or patches if available.

---

## Supported Versions

Security updates are actively maintained on the latest minor releases:

| Version Line | Supported | Notes |
|---|---|---|
| `1.0.x` | Yes | Active production and evaluation release |
| `< 1.0.0` | No | Pre-release preview branches |

---

## Security Model Overview

Agent Gateway enforces security at multiple layers:

### 1. Cryptographic Workload & User Identity
- **Human Identity**: Integrated with OpenID Connect (OIDC). Delegations require human verification via signed OIDC ID tokens from an enterprise identity provider (Keycloak, Okta, Microsoft Entra, Google, Dex).
- **Agent Workload Authentication**: Agents authenticate with per-delegation credentials (`agent_secret` / SPIFFE workload identity) before token minting is permitted.

### 2. Sender-Constrained Tokens (RFC 9449 DPoP)
- Tokens can be cryptographically bound to an asymmetric private key held by the agent runtime (`ES256`, `RS256`, `EdDSA`).
- Every presentation to the Policy Enforcement Point (PEP) requires a fresh DPoP proof matching the HTTP method, URI, and `ath` (access token hash).
- Replay attacks are rejected using an in-memory `jti` replay cache.
- Exfiltrated tokens cannot be used as Bearer tokens or replayed without the private key.

### 3. Least-Privilege Scoping (RFC 9396 RAR)
- Rich Authorization Requests (RAR) allow fine-grained downscoping of tokens to sub-task permissions (`resources`, `actions`, and quantitative `limits`).
- The token service strictly validates that requested authorization details are a subset of the parent human delegation.
- The PEP rejects tool calls exceeding the downscoped permissions (HTTP 403 Forbidden).

### 4. Human-in-the-Loop Approval & Single-Use Gating
- High-risk actions trigger approval holds (HTTP 202 Accepted).
- Approvals are cryptographically bound to an action hash (`SHA-256`) of the specific payload, ensuring agents cannot substitute arguments between approval and execution.
- Human approval tokens are strictly single-use and expire within configurable timeframes.

### 5. Immediate Revocation
- Delegations can be revoked instantly via the Admin Console or API.
- Revocation propagation is sub-second via Redis `jti` blocklists and database transaction checkpoints.

---

## Safe Harbor

We consider security research conducted in good faith to be authorized. We commit not to initiate legal action against researchers who:
- Make a good faith effort to avoid privacy violations, degradation of user experience, and disruption to production systems.
- Give us reasonable time to investigate and mitigate vulnerabilities before public disclosure.
- Do not exploit a vulnerability beyond what is strictly necessary to prove its existence.

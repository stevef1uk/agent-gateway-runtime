# Security model

How Agent Gateway answers the standard agent-security questions. See [Architecture.md](Architecture.md) for the components and request flow.

| Question | What this project does |
|---|---|
| **How do we identify Agents?** | Agents authenticate with their *own* identity, never the human's: a short-lived delegation-scoped JWT (minted by `tokensvc` against a one-time per-delegation agent secret) or a SPIFFE/SPIRE mTLS SVID (`X-Delegation-ID` header binds the SVID to a delegation). Claims carry `agent_id`, `user_id`, `delegation_id`. |
| **How do we control what Agents can call / which Tools or MCP Servers?** | Delegations carry explicit resource + action allowlists. Every call is re-authorized at the gateway (`POST authz /v1/check` with resource, action, args). The egress proxy (`:8088`) treats destination host = resource and HTTP method/CONNECT = action — all outbound traffic, including MCP/external tool calls, passes the same policy pipeline (OPA/Rego or built-in rules). |
| **How do we enable delegated authority?** | The human (verified via OIDC ID token) creates a delegation: resources, actions, limits, expiry, approval rules, `MaxDepth`. Authz returns a one-time agent secret + first token. Child delegations are only created via `Attenuate()` — strictly narrower than the parent. |
| **Can authorisation be decided per call, in context?** | Yes — core design. Each call is a fresh `POST /v1/check` with full context (delegation, agent, user, resource, action, args). OPA/Rego is evaluated per call (optional short-TTL Redis cache); the authz check always precedes approval consumption, so policy and revocation apply mid-session. |
| **How do we prevent Agents being hijacked or manipulated?** | 5-minute default tokens with `jti` + instant Redis revocation; tokens valid only for their single delegation; admin API gated by `X-Admin-Token`; approver binding (`approver_id` must equal the delegation's verified subject); per-IP rate limiting; SSRF guard; egress host allowlists with internal services non-tunnelable. |
| **How do we avoid Agents holding sensitive credentials?** | Agents never see user passwords, cookies, refresh tokens, or raw API keys. They hold only a scoped token derived from a one-time secret (stored as SHA-256 digest; digest never leaves authz). Upstream sees identity *headers* (`X-Auth-User`, `X-Auth-Agent`, `X-Delegation-ID`) injected by the gateway, not agent-held human credentials. Token exchange can downscope further. |
| **How do we control the blast radius of a compromised Agent?** | The delegation *is* the blast radius: resource/action allowlists, limits, TTL, `MaxDepth`. Revocation is immediate at the PEP even while tokens are cryptographically valid. Approvals are single-use and action-hash-bound (SHA-256 of resource+action+args — changed details = new hash = re-approval). Everything is audited for forensics. |
| **How do we handle Agent-to-Agent chains?** | Parent/child delegations with mandatory attenuation (`Attenuate()`, `MaxDepth`) — a child can never exceed its parent's authority, and each hop keeps its own `delegation_id` through checks and audit. |
| **When does a Human need to approve?** | Whenever the delegation's `ApprovalRule` marks an action high-risk (e.g., over a monetary cap): gateway returns `202`, records an approval bound to `(delegation_id, action_hash)`, notifies via HMAC-signed webhook or Telegram; the human approves via the web console or automation. Approvals are consumed single-use and expire; revocation beats a pending approval. |
| **How do we audit what happened and when?** | An append-only event per decision: request_id, user/agent/delegation ids, tool, resource, action, args_hash, outcome, reason, policy_id, approval_id, status, duration. Written as stdout JSON lines (dev) or to Postgres `audit_events` (prod); viewable in the web console, ready for SIEM streaming. |
| **How do we revoke delegated authorities?** | Two levels, both immediate: `DELETE authz /v1/delegations/{id}` (re-checked on *every* decision — revoke beats token validity and pending approvals) and `POST gateway /v1/tokens/revoke` (Redis `jti`, kills individual tokens instantly). TTL expiry handles the passive case. |
| **How do we verify the supply chain?** | Deliberately tiny dependency set (chi, pgx, go-redis, go-oidc; zero generated code), `govulncheck` clean, Trivy HIGH/CRITICAL-clean images, multi-arch ELF verification, and shipped images are encrypted + licence-gated via `secure-packager` with RSA licence tokens and a key-drift guard before builds. |

## How it is verified

- **Unit + integration tests** — `make test` across 14 packages (~43% of first-party Go is tests); integration tests cover the allow/deny/approval enforcement loop and audit output.
- **Browser end-to-end** — `make e2e-playground` drives SSO sign-in, delegation, and the approval flow in a real browser.
- **OWASP ZAP** — baseline and full scans against all four services plus the egress proxy listener (`scripts/zap-proxy.sh`); 0 fails.
- **`govulncheck`** — clean (Go toolchain 1.26.9).
- **Trivy** — container image scans of all four service images, clean for HIGH/CRITICAL.
- **Multi-arch verification** — arm64 image manifests assert correct aarch64 ELF binaries.
- **Live cluster smoke test** — k3s deployment end-to-end.

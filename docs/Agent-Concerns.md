# Common AI Agent Concerns — How Agent Gateway Helps

If you're wondering *"should I let an AI agent touch my production systems?"*
these are the questions most security and platform teams ask — and how Agent
Gateway answers each one:

| Your concern | How Agent Gateway addresses it | See |
|-------------|-------------------------------|-----|
| **The agent does something I didn't approve** | Every call is re-authorized at the PEP; high-risk actions return `202` held-for-approval and wait for a human decision before executing | [Demo 1](Demos.md#demo-1---scripted-demodemosh), [Protecting-Your-API.md](Protecting-Your-API.md) |
| **A stolen agent token is used by an attacker** | Short-lived JWTs (5 min default) + DPoP sender-constrained tokens bound to the agent's key; stolen tokens can't be replayed without the private key | [DPoP-and-RAR.md](DPoP-and-RAR.md), [Demo 10](Demos.md#demo-10---dpop-rfc-9449--rar-rfc-9396-live-verification-demodpop-rar-demosh) |
| **The agent has more access than it needs** | Delegations are least-privilege by construction: explicit resources, actions, spend caps, expiry, and max depth | [Protecting-Your-API.md](Protecting-Your-API.md), [Agent-Auth-Basics.md](Agent-Auth-Basics.md) |
| **Revocation is too slow — tokens stay valid for minutes** | Revoke a delegation and it's denied at the PEP *instantly*, even while the JWT is still cryptographically valid; token `jti` can also be killed in Redis | [Security-Model.md](Security-Model.md), [Demo 11](Demos.md#demo-11---the-kill-switch-demokill-switch-demosh) |
| **Prompt injection tricks the agent into unauthorized actions** | Reads can be auto-allowed, but every write/delete/payment is held for a human decision — the model can't override a human hold | [Demo 8 — Human Delegation under prompt injection](Demos.md#demo-8---human-delegation-under-prompt-injection-demohuman-delegation-demosh) |
| **No audit trail of what the agent actually did** | Every decision (allow/hold/deny/approve) is recorded with principal, agent, resource, action, reason, and timestamp — ready for SIEM | [UI-Walkthrough.md](UI-Walkthrough.md), [Architecture.md](Architecture.md) |
| **The agent calls external hosts I don't control** | Egress proxy (`:8088`) treats destination host = resource; every outbound call is one authorization decision, with human approval per call if you want | [Demo 5](Demos.md#demo-5---all-outbound-egress-via-the-gateway-approved-per-call-demoegress-demosh), [Architecture — egress enforcement](Architecture.md#egress-enforcement--every-outbound-call-is-one-decision) |
| **Agent-to-agent chains amplify blast radius** | Child delegations must attenuate (narrower than parent) with `MaxDepth` limiting hop count | [Security-Model.md](Security-Model.md), [Agent-Identity.md](Agent-Identity.md) |
| **MCP servers are wide open today** | Put a dedicated gateway instance in front of any MCP server; unauthenticated calls get `401`, destructive tools are held for human approval | [Protecting-Your-MCP.md](Protecting-Your-MCP.md), [Demo 9](Demos.md#demo-9---mcp-under-the-gateway-demomcp-demosh-openclaw-edition) |
| **I need to cut an agent off right now** | Kill switch: revoke one delegation (that agent → 403) or all delegations to an upstream (all agents → 403) instantly | [Demo 11](Demos.md#demo-11---the-kill-switch-demokill-switch-demosh) |
| **I need to prove compliance to auditors** | Immutable append-only audit events + approval records + approver binding, all queryable from the console or SIEM | [UI-Walkthrough.md](UI-Walkthrough.md), [Deployment-Guide.md](Deployment-Guide.md) |

For a fuller treatment of assumptions, threat boundaries and limitations, see the [Security Model](Security-Model.md). These controls enforce delegated authority; they do not make an agent's reasoning or outputs inherently trustworthy.

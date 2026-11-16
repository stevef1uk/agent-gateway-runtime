# Why Agent Gateway?

## Why not just use an existing API gateway, service mesh, or OPA sidecar?

Those tools are excellent at what they were designed for: routing, rate
limiting, mTLS, JWT validation, and general policy enforcement. Agent Gateway
is complementary, not a replacement. Keep using them for the infrastructure
layer.

Agent Gateway addresses a different need: giving an autonomous agent
fine-grained authority on behalf of a human, while keeping that human in
control of consequential actions.

### The missing agent control loop

API gateways and service meshes can enforce identity, claims, and network
policy. They are essential controls, but by themselves they do not provide
the full lifecycle of a human-issued delegation: authority scoped to the
agent's resources and actions, bounded by limits and expiry, with selected
actions held for a human decision.

An agent-facing control needs more than a network-level allow or deny. Routine
work should proceed within the authority granted, while a consequential action
such as a payment, deletion, production change, or outbound email can be held
for review before it reaches the protected system.

### Policy engines are part of the picture

OPA and other policy engines provide powerful policy-as-code. Agent Gateway
can use OPA as its policy engine; the project also provides a built-in policy
engine. Either way, the policy decision is part of a broader control plane
that supports:

- agent identity and scoped token issuance;
- delegation creation, limits, expiry, and lifecycle;
- human approval workflows for actions requiring review;
- revocation that takes effect even while a token remains cryptographically
  valid; and
- an audit trail recording the agent request and the decision, including the
  human approval outcome.

For details on the policy engines and their decision contract, see
[Policy and OPA](Policy-and-OPA.md).

### Designed for agent-specific risks

Agents can be influenced by prompt injection, may repeatedly retry denied
actions, and can execute consequential operations at machine speed. A robust
control should not depend solely on the agent following instructions. It
should enforce the agent's delegated authority at the point where it accesses
a tool, API, or service, and provide a human decision path where policy
requires one.

## In short

Use your existing API gateway, service mesh, and policy engine for the
infrastructure layer. Use Agent Gateway when you need to give an AI agent
real, fine-grained authority while keeping a human firmly in the loop.

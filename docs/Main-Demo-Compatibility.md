# Main-branch demo compatibility on AWS

Additional OpenClaw/OpenShell and backend hosts are customer-managed; supplied scripts do not provision them. Follow [customer-managed demo host setup](Customer-Managed-Demos.md) when you choose to run those integrations.

The AWS presets have [dedicated runners](AWS-Demos.md). This matrix describes prerequisites for the numbered `main` workflows. It does not claim the original scripts, with local Docker/Dex/admin assumptions, run unchanged against AWS.

| Main demo | Start proxy VM first? | AWS path and other prerequisites |
|---|---|---|
| 1 Scripted purchasing | **No** for direct API calls | Needs purchasing backend and matching allow/amount/approval delegation. Refunds preset is a simulation, not that backend |
| 2 Graphical walkthrough | **No** for direct API calls | AWS console supplies delegation/approval/audit UI; local demo UI/fixture setup is separate |
| 3 OPA playground | **No** | Administrator-only Console Rego editor, DynamoDB-backed version history, per-delegation engine selection, and live authorization probes are available when `EnableRegoPolicy=true` (default) |
| 4 Protected API | **No** | Dedicated API Lambda PEP and reachable HTTPS backend; users/refunds clients are provided examples |
| 5 Outbound egress | **Yes** | SSM tunnel plus host/action-scoped egress delegation; AWS HTTP proxy probe is provided |
| 6 OpenClaw/OpenShell sandbox | **No** for sandbox-only setup | Customer runs sandbox/model tools separately; outbound governed proxy use then needs VM |
| 7 Sandbox egress rules | **Yes** for gateway-backed egress | Customer sandbox plus VM/tunnel; sandbox-only rule demonstration is independent |
| 8 Invoice/prompt injection and human delegation | **Yes** for existing sandbox egress route; **No** for direct API adaptation | Needs invoice/payment backend and sandbox credentials. Proxy does not deploy them |
| 9 MCP/CRM | **No** for direct MCP; **Yes** for sandbox egress | Needs CRM MCP/backend. Emotion runner demonstrates direct MCP method approval, not CRM hosting |
| 10 DPoP/RAR | **No** for direct protected HTTP | Requires client proof generation/key binding and exact public URL. Basic AWS runner uses Bearer; it does not claim DPoP coverage |
| 11 Kill switch | **No** for direct API/MCP; **Yes** for proxy traffic | Revoking a delegation denies subsequent governed calls. Existing CONNECT tunnels and arbitrary processes are not retroactively killed |
| 12 Approval edge cases | **No** for direct API/MCP | Native local Go tests cover atomic approval/replay behavior; AWS held/approved phases cover basic single-use flow, not every main harness case |
| 13 Public weather | **No** | Baseline forecast/elevation tutorial or child weather runner; use the correct GatewayURL and route prefix |
| 14 Gmail approvals | **No** for direct connector API/MCP; **Yes** if using forward-proxy mode | Needs separately hosted Gmail connector, OAuth consent/refresh credentials and state. VM alone does not supply Gmail |

The optional VM provides HTTP forward proxy and HTTPS CONNECT transport. It is a single instance in one AZ, without automated infrastructure failover. A proxy requirement applies to the client's connection mode, not to an API's name.

HTTPS CONNECT authorizes the destination at tunnel establishment; TLS payload methods/bodies are opaque. An already-open tunnel is not terminated by revoking a delegation. Use a direct API/MCP PEP when individual operation approval is required.

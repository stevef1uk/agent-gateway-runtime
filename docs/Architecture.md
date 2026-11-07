# AWS weather-demo architecture

A human signs in through Cognito at the deployed web console. Their server-side
session creates a delegation for an agent. The agent sends a short-lived Bearer
token to the public weather gateway. Gateway checks delegation/policy through an
IAM-authenticated authz API; an allowed request is forwarded to Open-Meteo with
its path/query preserved and gateway credentials/identity headers stripped.

Elevation is configured to require a human decision. A 202 hold does not execute
the weather request. The signed-in delegating human records consent in the console;
one retry consumes it. Revocation and audit use shared DynamoDB state. IAM is
workload authentication; it does not grant application tool authority or approval.

The source infrastructure has four Lambda services and separate public/internal
HTTP APIs. Internal APIs are internet-addressable HTTPS with AWS_IAM authorization,
not VPC-private networks. The public weather ingress uses three exact optional
routes, never a wildcard exposing management APIs. Standard OAuth/console state,
replay and revocation are shared in DynamoDB; Cognito browser login replaces demo
Dex/password fixtures. Server-side admin/signing secrets are not handed to agents.

See the [source architecture](https://github.com/stevef1uk/agent-gateway/blob/aws/docs/aws/architecture.md)
and [deployment security boundaries](https://github.com/stevef1uk/agent-gateway/blob/aws/docs/aws/serverless-deployment.md).
This runtime branch does not duplicate those implementations or claim real AWS
acceptance before it has been run.

## Boundaries

- Open-Meteo stays public. Direct calls can bypass this demonstration; universal
  agent egress enforcement needs separate network/proxy controls.
- Authorization here matches actual weather paths/methods. Coordinates/query values
  are not constrained and approval is not a demonstrated query-specific binding.
- No provider-side execution counter is available; use gateway audit/status/data evidence.
- This is REST, not MCP discovery/tools or a DPoP client-signing acceptance test.
- Lambda buffers responses. CONNECT, SPIFFE listeners, WebSockets and live streams
  are not provided by this profile.
- Global pause, tenant-wide rates, mutable policy/catalog controls, coordinated key
  rotation, fault/load HA acceptance and Marketplace delivery remain unfinished.
- VM/Kubernetes backup/policy/notification/demo workflows are disabled in the
  serverless profile; do not infer them from videos or the main branch's guides.

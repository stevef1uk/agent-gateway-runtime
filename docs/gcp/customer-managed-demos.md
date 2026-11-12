# Customer-managed integrations for GCP demos

OpenClaw/OpenShell sandboxes, CRM or Gmail connectors, purchasing services,
and other application backends are not created by the published-image GCP
deployment. The supplied deploy script creates the Agent Gateway control
plane and its demo routes; it does not provision customer hosts or upstream
APIs/MCP servers. Existing reachable HTTP(S) APIs and MCP servers can be
registered through the GCP Console.

No separate GCP forward-proxy service is deployed. The public web Console
service proxies supported, configured API/MCP requests to the private Gateway.
This provides per-request Gateway policy for those routes; it is not a
generic egress proxy and does not govern unrelated traffic from a customer
host or sandbox.

## Before connecting a customer-hosted agent

- Operate the sandbox, model provider, tools, and application backends
  separately. You are responsible for their versions, security updates,
  credentials, availability, and costs.
- Use a delegation for a configured route and give the client only its
  short-lived agent access token. Keep the agent secret and provider
  credentials in the client's secret store, not in prompts, source control, or
  logs.
- Configure the client to call the public Console Cloud Run URL on the
  specific governed route. Do not configure it to call the private Gateway
  URL or the upstream service directly.
- Test the connection and denial/approval cases from the same client and
  network context that the agent will use. A successful request from an
  operator workstation does not prove that a remote sandbox can reach the
  Console.
- Limit the sandbox's other network paths if the goal is to ensure that its
  traffic cannot bypass the governed routes. The Gateway does not control
  direct connections to other hosts.

## Register an existing API or MCP server

Use the Console wizard to register the service's reachable HTTP(S) base URL,
then create a delegation scoped to the required route and actions. Follow the
[custom-upstream walkthrough](local-custom-upstream-wizard-test.md) for a
worked example and credential-handling details. The Gateway must be able to
reach the upstream; registration does not deploy it or configure its network
access. For upstream authentication, callers supply their own credentials
per request. Registering a route is not generic egress enforcement.

The built-in weather, geocoding, users, refunds, and optional Emotion routes
are deployment-configured. The Console's Delete action applies to
customer-registered upstreams, not these built-in demos.

## Limits of the available demos

- The refunds route targets JSONPlaceholder `/posts`; no real payment or
  refund is performed, and simulated writes are not durable.
- The optional Emotion service is shared by the deployment. It uses the
  image's bundled evaluation token unless a separate vendor-issued Emotion
  token is configured. This is separate from the Agent Gateway activation
  token. See the [GCP deployment guide](../GCP-Deployment-Guide.md) before
  enabling Emotion.
- There is no deployed generic proxy for OpenClaw/OpenShell outbound traffic.
  Using the public Console URL for an explicit supported API/MCP call does not
  turn that path into whole-sandbox egress enforcement.
- Revoking a delegation blocks later governed calls but does not stop work
  already accepted by an upstream or terminate unrelated sandbox processes.

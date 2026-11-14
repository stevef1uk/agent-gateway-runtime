# Azure documentation

This directory records the original Azure proposal and design work in this
runtime repository. The current Azure application implementation and
operator-tested install/teardown instructions live in the separate
[`stevef1uk/agent-gateway` repository](https://github.com/stevef1uk/agent-gateway/tree/azure).
The development trial is verified by the operator but is not
production-certified.

- [Current Azure install and release instructions](https://github.com/stevef1uk/agent-gateway/blob/azure/deploy/azure/README.md)
- [Current live deployment status](https://github.com/stevef1uk/agent-gateway/blob/azure/docs/azure/live-deployment.md)
- [Current Azure architecture](https://github.com/stevef1uk/agent-gateway/blob/azure/docs/azure/architecture.md)
- [Full Azure teardown runbook](https://github.com/stevef1uk/agent-gateway/blob/azure/docs/azure/teardown.md)
- [Current implementation and acceptance plan](https://github.com/stevef1uk/agent-gateway/blob/azure/docs/azure/implementation-plan.md)

The files below retain proposal assumptions, pricing, and the Neon helper
design. Use the linked application-repository docs for a new installation;
the proposal pages are not the current installer or deployment status.

- [Original architecture proposal](architecture.md)
- [Original deployment proposal](../Azure-Deployment-Guide.md)
- [Indicative pricing assumptions](serverless-pricing.md)
- [Original implementation plan](implementation-plan.md)

The Neon setup helper supports creating/selecting a project/database and
ownership-checked removal of a project it created. It does not deploy Azure
resources or implement the Agent Gateway application's PostgreSQL state.

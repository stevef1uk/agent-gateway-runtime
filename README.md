# Agent Gateway — Azure proposal

This branch contains a low-cost, serverless deployment proposal for running
Agent Gateway on Microsoft Azure. It is intentionally limited to this README
and the Azure proposal documentation; it does not contain application source,
deployment automation, or infrastructure-as-code.

Start here:

- [Azure deployment proposal](docs/Azure-Deployment-Guide.md)
- [Architecture and Azure service choices](docs/azure/architecture.md)
- [Indicative pricing and assumptions](docs/azure/serverless-pricing.md)
- [Azure documentation index](docs/azure/README.md)

The estimate favors Azure Container Apps Consumption, with the web console
kept at one replica and the other services able to scale to zero. Durable
PostgreSQL is shown as a separately costed option. See the architecture and
pricing documents for limitations, exclusions, and assumptions.

This is a proposal only. No Azure resources are deployed by this branch.

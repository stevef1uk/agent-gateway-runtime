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

The proposal favors Azure Container Apps Consumption with scale-to-zero and
uses an existing Neon PostgreSQL database by default. Shared Neon-backed web
OIDC sessions are a target design that requires application support; the
current web image still stores those sessions in memory. Azure Database for
PostgreSQL is an optional, separately costed alternative. See the architecture
and pricing documents for limitations, exclusions, and assumptions.

This is a proposal only. No Azure resources are deployed by this branch.

# Agent Gateway — Azure proposal

This branch contains a low-cost, serverless deployment proposal for running
Agent Gateway on Microsoft Azure, plus an initial Neon configuration/status
helper. It does not contain Agent Gateway application source, a complete
deployment installer, or infrastructure-as-code.

Start here:

- [Azure deployment proposal](docs/Azure-Deployment-Guide.md)
- [Architecture and Azure service choices](docs/azure/architecture.md)
- [Indicative pricing and assumptions](docs/azure/serverless-pricing.md)
- [Implementation plan and test gates](docs/azure/implementation-plan.md)
- [Azure documentation index](docs/azure/README.md)

The target proposal uses Azure Container Apps Consumption and Neon PostgreSQL.
Neon provisioning and persistence/session integration are planned early, with
a scripted installer driven by a user-created environment/account config.
Persisting web OIDC state and sessions in Neon is required before safely
scaling the web app to zero; the current web image still stores those sessions
in memory. The initial Phase 1 helper validates a non-secret Neon config and
reads metadata for an existing project; it does not create Neon resources or
change the application database. Azure Database for PostgreSQL is an optional,
separately costed alternative. See the architecture, implementation plan, and
pricing documents for test gates, limitations, exclusions, and assumptions.

This is a proposal only. No Azure resources are deployed by this branch.

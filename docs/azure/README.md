# Azure proposal

This branch proposes a low-cost, serverless deployment of Agent Gateway in
Microsoft Azure. It is a design and cost model, **not an executable deployment
or a promise that Azure resources have been created**.

- [Architecture and Azure service choices](architecture.md)
- [Deployment proposal](../Azure-Deployment-Guide.md)
- [Indicative pricing and assumptions](serverless-pricing.md)

The default design uses Azure Container Apps Consumption for the four existing
service containers, with all four able to scale to zero, and an existing Neon
PostgreSQL database for durable state. Azure Database for PostgreSQL is an
optional, separately costed alternative. The web console's in-memory OIDC
session state can make sign-in unreliable after scale-to-zero. Moving that
session state into Neon is the target design but requires application support
not present in the current web image; until then, keeping one replica warm is
the reliability option.

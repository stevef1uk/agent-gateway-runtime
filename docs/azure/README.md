# Azure proposal

This branch proposes a low-cost, serverless deployment of Agent Gateway in
Microsoft Azure. It is a design and cost model, **not an executable deployment
or a promise that Azure resources have been created**.

- [Architecture and Azure service choices](architecture.md)
- [Deployment proposal](../Azure-Deployment-Guide.md)
- [Indicative pricing and assumptions](serverless-pricing.md)

The default design uses Azure Container Apps Consumption for the four existing
service containers. It keeps the web console at one replica for its in-memory
OIDC session state, and lets the other services scale to zero. A managed
PostgreSQL server is an optional costed add-on for durable state; the cheapest
memory-only pilot is not suitable for retaining an audit record.

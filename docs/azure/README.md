# Azure proposal

This branch proposes a low-cost, serverless deployment of Agent Gateway in
Microsoft Azure. It is a design and cost model, **not an executable deployment
or a promise that Azure resources have been created**.

- [Architecture and Azure service choices](architecture.md)
- [Deployment proposal](../Azure-Deployment-Guide.md)
- [Indicative pricing and assumptions](serverless-pricing.md)
- [Implementation plan and test gates](implementation-plan.md)

The target design uses Azure Container Apps Consumption and Neon PostgreSQL.
Phase 1 includes config-driven Neon project/database/role setup and
ownership-checked teardown in `scripts/neon_setup.py`; application database
integration remains to be implemented. Web OIDC state and sessions
must be persisted in Neon before `web` can safely scale to zero; until that
application/image change passes its cold-callback tests, keep one replica
warm. Azure Database for PostgreSQL is an optional, separately costed
alternative.

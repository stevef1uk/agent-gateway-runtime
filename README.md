# Agent Gateway — Azure integration documentation

This repository contains Azure architecture/proposal documents and a local
Neon project setup helper. The Azure application source and deployable
infrastructure are maintained in the separate
[`stevef1uk/agent-gateway` repository](https://github.com/stevef1uk/agent-gateway/tree/azure).
That repository contains the application code, Azure Terraform scaffold,
guarded deployment/teardown wrapper, and Key Vault uploader.

The operator-verified Azure development trial and the instructions for
installing or removing the application are documented in the application
repository. The trial is not production-certified.

## Current Azure install and teardown

- [Azure deployment and release README](https://github.com/stevef1uk/agent-gateway/blob/azure/deploy/azure/README.md)
- [Live development status](https://github.com/stevef1uk/agent-gateway/blob/azure/docs/azure/live-deployment.md)
- [Current Azure architecture and enterprise integration proposal](https://github.com/stevef1uk/agent-gateway/blob/azure/docs/azure/architecture.md)
- [Full Azure teardown runbook](https://github.com/stevef1uk/agent-gateway/blob/azure/docs/azure/teardown.md)
- [Application implementation and acceptance plan](https://github.com/stevef1uk/agent-gateway/blob/azure/docs/azure/implementation-plan.md)

Use the files in this repository for the Azure design proposal, cost model,
and Neon helper details:

- [Azure documentation index](docs/azure/README.md)
- [Azure deployment proposal and history](docs/Azure-Deployment-Guide.md)
- [Proposed architecture](docs/azure/architecture.md)
- [Indicative pricing and assumptions](docs/azure/serverless-pricing.md)
- [Original implementation plan](docs/azure/implementation-plan.md)

The Neon helper provisions or selects a Neon project/database and can remove a
project it created after exact confirmation. It does not deploy Azure
resources or modify Agent Gateway application data. The helper and proposal
documents are not substitutes for the application repository's guarded Azure
installer.

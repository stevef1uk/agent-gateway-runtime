# Agent Gateway — Azure documentation

This repository is the user-facing source for the Azure design and deployment
status. It contains architecture and pricing documents and a local Neon
project setup helper. It does **not** currently contain the Agent Gateway
application source, container build files, Terraform deployment, Azure
install/upgrade/teardown commands, or Key Vault secret uploader. You cannot
install or remove a complete Agent Gateway deployment using this checkout
alone.

An operator previously verified an Azure development trial, but that trial is
not production-certified and is no longer deployed. The application stack,
dedicated Key Vault, and Terraform state storage account have been removed
from active Azure resources. Azure retains the purge-protected Key Vault in
soft-deleted state. Neon and Entra resources were outside this Azure teardown
and may remain; their ownership and current state must be checked separately.
The deployment used tooling not included in this public repository.

## Azure documentation in this repository

- [Azure documentation index](docs/azure/README.md)
- [Deployment design and Neon setup helper guide](docs/Azure-Deployment-Guide.md)
- [Proposed architecture and enterprise integration](docs/azure/architecture.md)
- [Azure trial status and teardown verification](docs/azure/trial-status.md)
- [Azure teardown guidance](docs/azure/teardown.md)
- [Azure custom API and MCP wizard walkthrough](docs/azure/local-custom-upstream-wizard-test.md)
- [Historical implementation plan and acceptance gates](docs/azure/implementation-plan.md)
- [Indicative pricing and assumptions](docs/azure/serverless-pricing.md)

The Neon helper provisions or selects a Neon project/database and can remove a
project it created after exact confirmation. It does not deploy Azure
resources or modify Agent Gateway application data. The Azure deployment
material is design and acceptance guidance, not an executable installer. Do
not apply the manual resource outline as a substitute for reviewed,
version-controlled deployment automation.

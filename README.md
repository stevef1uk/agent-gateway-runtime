# Agent Gateway — Azure documentation

This repository is the user-facing source for the Azure design and deployment
tools. It contains Azure Bicep infrastructure, a guarded deployment and
teardown script, and a Key Vault secret uploader. It does **not** contain the
Agent Gateway application source or container build files: deployments use
licensed, prebuilt images published by the release owner. Users cannot build
or modify those images from this repository.

An operator previously verified an Azure development trial, but that trial is
not production-certified and is no longer deployed. The application stack,
dedicated Key Vault, and Terraform state storage account have been removed
from active Azure resources. Azure retains the purge-protected Key Vault in
soft-deleted state. Neon and Entra resources were outside this Azure teardown
and may remain; their ownership and current state must be checked separately.
The deployment tooling now in this public repository has not yet been used to
recreate that trial and does not imply production certification.

## Azure documentation in this repository

- [Azure documentation index](docs/azure/README.md)
- [Azure deployment guide](docs/Azure-Deployment-Guide.md)
- [Proposed architecture and enterprise integration](docs/azure/architecture.md)
- [Azure trial status and teardown verification](docs/azure/trial-status.md)
- [Azure teardown guidance](docs/azure/teardown.md)
- [Azure custom API and MCP wizard walkthrough](docs/azure/local-custom-upstream-wizard-test.md)
- [Historical implementation plan and acceptance gates](docs/azure/implementation-plan.md)
- [Indicative pricing and assumptions](docs/azure/serverless-pricing.md)

The Azure installer deploys only immutable prebuilt image digests, uses
Key-Vault-backed runtime secrets, checks the active tenant/subscription, shows
an Azure What-If preview, and requires exact confirmation before applying or
deleting dedicated resource groups. Read the deployment and teardown guides
before using it; a successful ARM deployment is not a substitute for
application-level acceptance testing.

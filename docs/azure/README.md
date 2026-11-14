# Azure documentation

This repository is the Azure documentation available to users. An operator
verified a development trial, but it was not production-certified and has
since been torn down. Its application resources and dedicated Terraform
backend are no longer active; the purge-protected Key Vault remains in Azure
soft-deleted state. Neon and Entra resources were outside the Azure teardown.

**This checkout does not include Agent Gateway application source, container
build files, Terraform, Azure install/upgrade/teardown commands, or a Key
Vault uploader. The documents here do not provide an executable deployment.
Do not treat the design outline as instructions to create production
resources.**

- [Deployment design and Neon setup helper guide](../Azure-Deployment-Guide.md)
- [Proposed architecture and enterprise integration](architecture.md)
- [Azure trial status and teardown verification](trial-status.md)
- [Azure teardown guidance](teardown.md)
- [Custom API and MCP wizard walkthrough](local-custom-upstream-wizard-test.md)
- [Historical implementation plan and acceptance gates](implementation-plan.md)
- [Indicative pricing assumptions](serverless-pricing.md)

The Neon helper supports creating/selecting a project/database and
ownership-checked removal of a project it created. It does not deploy Azure
resources or implement the Agent Gateway application's PostgreSQL state.

# Azure documentation

This repository is the Azure documentation available to users. The operator
verified a development trial, but the trial is not production-certified and
its current resource state must be checked independently.

**This checkout does not include Agent Gateway application source, container
build files, Terraform, Azure install/upgrade/teardown commands, or a Key
Vault uploader. The documents here do not provide an executable deployment.
Do not treat the design outline as instructions to create production
resources.**

- [Deployment design and Neon setup helper guide](../Azure-Deployment-Guide.md)
- [Proposed architecture and enterprise integration](architecture.md)
- [Historical implementation plan and acceptance gates](implementation-plan.md)
- [Indicative pricing assumptions](serverless-pricing.md)

The Neon helper supports creating/selecting a project/database and
ownership-checked removal of a project it created. It does not deploy Azure
resources or implement the Agent Gateway application's PostgreSQL state.

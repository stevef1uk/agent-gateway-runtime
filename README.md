# Agent Gateway Runtime — Azure

Deploy Agent Gateway to Azure with the public Bicep template and deployment
tools in this repository. The supervised Azure development trial successfully
verified the Console, Policy/Rego page, Telegram configuration, and
wizard-managed Emotion service. This repository brings the Azure deployment
workflow to operators, including guarded provisioning and teardown plus secure
Key Vault secret upload.

Deployments use licensed, immutable container images published by the release
owner. The [deployment guide](docs/Azure-Deployment-Guide.md) walks through
prerequisites, configuration, deployment, and end-to-end validation. For the
design and history, see the [Azure architecture](docs/azure/architecture.md)
and [trial status](docs/azure/trial-status.md).

## Azure documentation in this repository

- [Azure documentation index](docs/azure/README.md)
- [Azure deployment guide](docs/Azure-Deployment-Guide.md)
- [Proposed architecture and enterprise integration](docs/azure/architecture.md)
- [Azure trial status and teardown verification](docs/azure/trial-status.md)
- [Azure teardown guidance](docs/azure/teardown.md)
- [Azure custom API and MCP wizard walkthrough](docs/azure/local-custom-upstream-wizard-test.md)
- [Historical implementation plan and acceptance gates](docs/azure/implementation-plan.md)
- [Indicative pricing and assumptions](docs/azure/serverless-pricing.md)

The installer deploys immutable image digests, uses Key-Vault-backed runtime
secrets, verifies the active tenant and subscription, previews changes with
Azure What-If, and asks for exact confirmation before applying or deleting
dedicated resource groups. Follow the deployment guide's validation checklist
to confirm application behavior in your Azure environment.

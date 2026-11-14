# Azure documentation

Deploy Agent Gateway to Azure using the public Bicep template and lifecycle
tools in this repository. A supervised development trial successfully
exercised the Console, Policy/Rego page, Telegram configuration, and
wizard-managed Emotion service. The deployment guide takes operators from
prerequisites through deployment and end-to-end checks.

The Azure package includes infrastructure provisioning, lifecycle safeguards,
and Key Vault secret upload. Deployments use licensed, digest-pinned images
supplied by the release owner, so the application release stays consistent
while operators manage the Azure environment here.

- [Azure deployment guide](../Azure-Deployment-Guide.md)
- [Proposed architecture and enterprise integration](architecture.md)
- [Azure trial status and teardown verification](trial-status.md)
- [Azure teardown guidance](teardown.md)
- [Custom API and MCP wizard walkthrough](local-custom-upstream-wizard-test.md)
- [Azure implementation roadmap](implementation-plan.md)
- [Indicative pricing assumptions](serverless-pricing.md)

The current deployment uses PostgreSQL through Neon. The Neon helper prepares
the database credentials; operators provide an Entra app registration and add
the printed redirect URI after deployment. Licence and immutable image
references are release assets consumed by the installer, not additional cloud
services to provision. Microsoft SQL Server is not currently supported by the
installer and application-image contract.

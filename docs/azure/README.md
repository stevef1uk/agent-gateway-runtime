# Azure documentation

The supervised development trial was operator-tested but not
production-certified and has been torn down. The Azure deployment automation
now in this repository has not yet been used to recreate that trial.

This repository contains Azure Bicep infrastructure and deployment/teardown
automation, but not the Agent Gateway application source or container build
files. Deployments consume licensed, prebuilt, digest-pinned images supplied
by the release owner; users cannot build those images from this repository.

- [Azure deployment guide](../Azure-Deployment-Guide.md)
- [Proposed architecture and enterprise integration](architecture.md)
- [Azure trial status and teardown verification](trial-status.md)
- [Azure teardown guidance](teardown.md)
- [Custom API and MCP wizard walkthrough](local-custom-upstream-wizard-test.md)
- [Historical implementation plan and acceptance gates](implementation-plan.md)
- [Indicative pricing assumptions](serverless-pricing.md)

The installer requires a dedicated RBAC-enabled Key Vault, configured Neon
database, Entra OIDC app registration, licence token, and image release
digests. It does not create or delete those external resources.

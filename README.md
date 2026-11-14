# Agent Gateway Runtime — Azure

Bring Agent Gateway to your Azure environment with the deployment tools in this
repository. A supervised development trial successfully exercised the Console,
Policy/Rego page, Telegram configuration, and wizard-managed Emotion service.
The public Azure package makes it practical for operators to deploy the
licensed services with repeatable Bicep provisioning, secure Key Vault secret
handling, and ownership-aware teardown.

## Get started

Follow the [Azure deployment guide](docs/Azure-Deployment-Guide.md) to prepare
your Azure subscription, configure the release images and external services,
deploy the stack, and run the acceptance checks. The guide links to the
[architecture](docs/azure/architecture.md), [teardown instructions](docs/azure/teardown.md),
and [indicative cost model](docs/azure/serverless-pricing.md).

Deployments use immutable container images and licence material supplied by
the release owner. This keeps the application release consistent while letting
operators manage the Azure infrastructure from this public repository.

## Public evaluation licence expiry

The public evaluation licence in `keys/token.txt` expires on 31 December 2027.
The images enforce this signed expiry. To keep running after that date,
request a private replacement licence from the vendor. See the [Pricing page
in the main repository](https://github.com/stevef1uk/agent-gateway/blob/aws/docs/aws/pricing.md)
for licensing details.

## Azure resources and documentation

- [Azure documentation index](docs/azure/README.md)
- [Azure deployment guide](docs/Azure-Deployment-Guide.md)
- [Proposed architecture and enterprise integration](docs/azure/architecture.md)
- [Azure trial status and teardown verification](docs/azure/trial-status.md)
- [Azure teardown guidance](docs/azure/teardown.md)
- [Azure custom API and MCP wizard walkthrough](docs/azure/local-custom-upstream-wizard-test.md)
- [Azure implementation roadmap](docs/azure/implementation-plan.md)
- [Indicative pricing and assumptions](docs/azure/serverless-pricing.md)

The installer deploys immutable image digests, uses Key-Vault-backed runtime
secrets, verifies the active tenant and subscription, previews changes with
Azure What-If, and requires explicit confirmation before applying or deleting
dedicated resource groups. Its validation checklist helps confirm application
behavior in your Azure environment.

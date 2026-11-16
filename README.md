# Agent Gateway Runtime — Azure

Bring Agent Gateway to your Azure environment with the deployment tools in this
repository. A supervised development trial successfully exercised the Console,
Policy/Rego page, Telegram configuration, and wizard-managed Emotion service.
The public Azure package makes it practical for operators to deploy the
licensed services with repeatable Bicep provisioning, secure Key Vault secret
handling, and ownership-aware teardown.

**Sign Azure images:** In GitHub Actions, run **Sign Azure release images** with the `azure` branch selected. It signs the five immutable image digests in `deploy/azure/azure-config.example.json` without rebuilding them. Set repository Actions secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` first. The workflow summary lists the signed references. Verify one with Cosign identity `https://github.com/stevef1uk/agent-gateway-runtime/.github/workflows/sign-azure-images.yml@refs/heads/azure` and issuer `https://token.actions.githubusercontent.com`. This adds image signatures only—not an SBOM or provenance. See [image verification guidance](https://github.com/stevef1uk/agent-gateway-runtime/blob/main/docs/Container-Image-Security.md).

```bash
IMAGE='<exact immutable image reference from the workflow summary>'
cosign verify \
  --certificate-identity 'https://github.com/stevef1uk/agent-gateway-runtime/.github/workflows/sign-azure-images.yml@refs/heads/azure' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  "$IMAGE"
```

## Get started

Follow the [Azure deployment guide](docs/Azure-Deployment-Guide.md) to prepare
your Azure subscription and external services, deploy the bundled release,
and run the acceptance checks. The guide links to the
[architecture](docs/azure/architecture.md), [teardown instructions](docs/azure/teardown.md),
and [indicative cost model](docs/azure/serverless-pricing.md).

The repository includes digest-pinned images for the Azure development trial
and its public evaluation licence, so operators do not need access to the
application source repository or separate release assets. These references
are development-trial assets, not a production availability or support
guarantee. Private or extended licence files can be supplied as an override.

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

# Azure development trial status

The supervised Azure development trial was operator-tested but was not
production-certified. The Console, Policy/Rego page, Telegram configuration,
and wizard-managed Emotion service were confirmed working during the trial.
Those are historical results; there is no active Agent Gateway application
deployment from that trial.

## Teardown verification

On 14 November 2026, the guarded Terraform destroy completed with **0
resources added, 0 changed, and 14 destroyed**. The resulting Terraform state
was verified empty. The trial's application and Emotion resource groups were
removed.

The dedicated Terraform state storage account and its resource group were
deleted after the empty-state check. The dedicated Key Vault was deleted from
active resources, and its resource group was removed. Because purge protection
was enabled, Azure retains the vault in soft-deleted state under its retention
policy; its contents were not irreversibly erased. Neon and Entra were
outside the Azure teardown and were not deleted as part of it.

The public repository now includes Azure Bicep deployment automation and a
guarded lifecycle wrapper. That tooling has not yet been used to recreate
this trial and does not turn the historical trial into production
certification. The application source and container build files remain
proprietary; deployments must use release-owner-provided, immutable image
digests. See the [deployment guide](../Azure-Deployment-Guide.md) before
installing.

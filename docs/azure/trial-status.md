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

This checkout contains design documentation and a Neon helper only. It does
not include the application source, container build files, Terraform, Azure
deployment/destroy wrapper, or Key Vault uploader. The trial's status is not
an install promise; see the [README](../../README.md) before planning a new
deployment.

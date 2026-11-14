# Azure teardown guidance

This guide explains the ownership checks needed to remove a dedicated Agent
Gateway Azure deployment. It is not a general subscription cleanup procedure.
Keep pre-existing or shared resources. Stop if resource ownership or the
deployment's Terraform state is uncertain.

**This repository does not include the Azure installer, Terraform, or guarded
destroy wrapper.** If the deployment was created with those tools from
another checkout, use the same release and its guarded destroy command. Do
not replace a missing state-aware destroy with direct Azure resource deletion:
that can leave Terraform state inconsistent or remove shared infrastructure.

## 1. Confirm Azure context and ownership

Sign in using the account authorized to manage the deployment and check the
active tenant and subscription:

```sh
az account show --query '{tenant:tenantId,subscription:id}' --output table
```

Compare this context with the original deployment records. Identify the
application and optional Emotion resource groups, Key Vault, remote Terraform
state account, Entra app registration, and Neon project. Delete only
resources created exclusively for this deployment. Never copy account IDs,
tokens, database URLs, or secret values into this repository.

## 2. Remove wizard-managed services and the application stack

If the Console is available, remove a wizard-managed Emotion service through
its **Delete MCP** action first. This removes its route and the private
Container App together.

For a Terraform-managed application, run its original guarded destroy flow.
Review the full plan and require it to destroy only deployment-owned
resources. Confirm using the exact resource-group name only after the plan is
reviewed. Verify the application resource group is gone and the original
Terraform state contains no managed resources:

```sh
az group exists --name <application-resource-group>
terraform -chdir=<path-to-original-terraform> state list
```

The first command should return `false`; the state list should be empty.
Keep the state backend until both checks pass. If the original wrapper or
state is unavailable, stop and recover those from the deployment owner rather
than deleting resources directly.

## 3. Remove dedicated prerequisites only after the application destroy

The application destroy commonly leaves a separately managed Key Vault and
state backend. Remove them only if they were created for this deployment and
are not shared.

Delete the dedicated Key Vault from active resources:

```sh
az keyvault delete --name <demo-key-vault> \
  --resource-group <demo-key-vault-resource-group>
```

Azure soft-delete and purge-protection policies may keep the vault recoverable
and visible in deleted-vault listings. Do not disable or work around purge
protection, and do not claim the secrets were immediately or irreversibly
erased.

The Terraform state account is the last Azure resource to remove. First
verify that the guarded destroy succeeded and the state is empty, then verify
the storage account contains no other state or customer data:

```sh
az storage account delete --name <demo-state-storage-account> \
  --resource-group <demo-state-resource-group> --yes
```

This permanently removes the account and its state blobs/versions. Do not
delete a shared state backend. Once it is gone, the original Terraform
backend configuration cannot be reused.

For dedicated Key Vault or state resource groups, list resources and delete
the exact resource group only after confirming it is empty:

```sh
az resource list --resource-group <dedicated-resource-group> --output table
az group delete --name <dedicated-resource-group> --yes
```

## 4. Revert tenant and external-service changes only when owned

- For a shared Entra app registration, remove only the deployment-specific
  callback URI and client credential. Preserve unrelated redirect URIs,
  credentials, and applications. Delete the registration/service principal
  only if dedicated to the deployment.
- Neon is not an Azure resource. Delete a Neon project only if it was created
  exclusively for the deployment, after retaining any required data. Do not
  delete a shared or pre-existing project.
- Docker images, source, and documentation are not Azure resources and are
  not removed by Azure teardown.

## 5. Verify the final state

- No application or Emotion Container Apps remain in the dedicated resource
  groups; dedicated groups are deleted only if empty and owned by the demo.
- The dedicated Key Vault and state storage account are absent from active
  resources if their removal was authorized.
- Shared Entra applications and Neon projects remain intact; remove only
  demo-specific settings when applicable.
- Azure Activity Logs and a soft-deleted Key Vault can remain visible under
  Azure retention policies. These are expected remnants, not active
  application deployments.

For the state of the supervised trial, see [trial status](trial-status.md).

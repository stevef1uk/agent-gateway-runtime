# Azure teardown guidance

The public Azure deployment wrapper owns two dedicated resource groups: the
application group configured in `deploy/azure/azure-config.json` and the
Emotion demo group derived from `name_prefix`. The installer does not create
Terraform state. Use its ownership-checked destroy action rather than
manually deleting individual application resources.

## 1. Confirm context and review resources

Use the same config and Azure tenant/subscription as deployment:

```sh
az account show --query '{tenant:tenantId,subscription:id}' --output table
python3 -B scripts/deploy_azure.py destroy \
  --config deploy/azure/azure-config.json
```

The script refuses a mismatched account or an application group that lacks
its `managedBy=agent-gateway-runtime-azure` ownership tag. It lists every
resource in the application group and the Emotion group, if present, before
asking for the exact `DESTROY <application-resource-group>` confirmation.
Destroy deletes all resources in those groups asynchronously. Review the lists
and stop if either group contains data or resources that must be retained.

After confirming, verify deletion:

```sh
az group exists --name <application-resource-group>
az group exists --name <name-prefix>-emotion-demos
```

Both should eventually return `false`. Group deletion is asynchronous; check
again after Azure completes it.

## 2. External resources are not deleted

The wrapper preserves the existing Key Vault, pre-existing secrets, Neon
project/database, Entra app registration, image registry, and any resource
groups outside this deployment. It deletes only the Key Vault secrets it
uploaded and tagged for this deployment, and removes this runtime identity's
wrapper-created Key Vault Secrets User assignment. A pre-existing assignment
is retained. Deleted secrets may remain recoverable
under Key Vault soft-delete retention. Remove the callback URI from a shared
Entra application manually if appropriate. Delete a dedicated Key Vault,
Neon project, or Entra application only through its owner-approved workflow
and only after verifying that it is not shared.

Key Vault soft-delete and purge-protection retention are controlled by Azure.
The deployment wrapper does not purge a vault or bypass retention.

If you created a Neon project with the public helper, set `NEON_API_KEY`
securely, inspect its recorded project ID, and remove only that helper-owned
project:

```sh
python3 -B scripts/neon_setup.py --config config/neon.json status
python3 -B scripts/neon_setup.py --config config/neon.json destroy \
  --confirm-project-id THE_REVIEWED_PROJECT_ID
```

The helper refuses to delete a project it did not create. Remove only the
deployment-specific callback URI from a shared Entra app; delete a dedicated
registration only after verifying that it is not shared.

## 3. Interrupted or historical deployments

If `apply` stopped after its first confirmation, it may have created the
dedicated groups, managed identity, and Key Vault role assignment before the
Container Apps deployment. The same `destroy` command can remove those
resources after displaying them. If ownership checks fail or the script
cannot identify the identity, stop and inspect the resources with the Azure
administrator; do not remove a group by name alone.

The 2026 supervised trial used a separate Terraform deployment and has
already been torn down. Its status and verification details are in the
[trial record](trial-status.md); do not reuse that trial's resource names or
state assumptions for a new installation.

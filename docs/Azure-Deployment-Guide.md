# Agent Gateway Azure deployment guide

Deploy the licensed Agent Gateway services to Azure with the public Bicep
template and lifecycle tools in this repository. The workflow provisions the
Container Apps environment, securely connects runtime secrets through Key
Vault, previews infrastructure changes, and provides an ownership-aware
teardown path.

A supervised Azure development trial successfully exercised the Console,
Policy/Rego page, Telegram configuration, and wizard-managed Emotion service.
This guide helps you prepare your Azure environment, deploy the release-owner
images, and confirm the end-to-end experience with the acceptance checklist.
Begin in a non-production subscription, then use your results to plan rollout.

## What the installer manages

- Four Container Apps (`authz`, `gateway`, `tokensvc`, `web`) in one
  Consumption environment.
- A user-assigned managed identity with Key Vault secret-read access and
  scoped permissions for the Emotion wizard's dedicated resource group and
  Container Apps environment.
- Key Vault references for runtime secrets; secret values are not Bicep
  parameters or command-line arguments.
- A dedicated resource group named in the config and an Emotion demo resource
  group derived from `name_prefix`.
- Azure Monitor log destination for the Container Apps environment.

The deployment uses a Key Vault you select and a PostgreSQL connection. The
Neon helper can create or select the Neon project and database and produce the
credential file. The deployment scripts do not create or configure an Entra
app registration: you provide its client ID, issuer URL, and client-secret
file, then add the callback URI printed after deployment. The optional
private-registry setting configures pulls for the four Agent Gateway service
images. Make the Emotion image used by the wizard available to Azure Container
Apps independently.

## 1. Prerequisites

Install Python 3.10+ and Azure CLI with Bicep. Sign in to the intended tenant
and subscription; the script rejects a mismatch with the deployment config.
If Bicep is not installed, install it with `az bicep install`.

The deploying identity needs permission to create the listed Azure resources,
create a user-assigned managed identity, and create role assignments at the
configured Key Vault and new deployment scopes. A typical setup is Contributor
and User Access Administrator (or Role Based Access Control Administrator) at
the target subscription, plus Key Vault Secrets Officer at the external vault
for secret upload and cleanup. These are privileged permissions; have the
subscription administrator scope them according to your organization's
least-privilege policy. The Key Vault must already exist and use Azure RBAC
authorization.

Select a dedicated Key Vault, or create one in a separate resource group.
Choose a globally unique name that is not still soft-deleted from a previous
trial; do not purge a retained vault to reuse its name:

```sh
az group create --name rg-agent-gateway-secrets --location uksouth
az keyvault create \
  --name YOUR_UNIQUE_VAULT_NAME \
  --resource-group rg-agent-gateway-secrets \
  --location uksouth \
  --enable-rbac-authorization true
```

Set the matching vault name, resource group, and region in the config. Assign
the deployment operator the required Key Vault data-plane and role-assignment
permissions using your organization's approved RBAC process.

## External service setup

1. **Database:** The current installer and release-image contract use
   PostgreSQL. Run `scripts/neon_setup.py` to select an existing Neon project
   or create a dedicated one; the helper writes the owner-only
   `config/neon-credentials.json` used by the Azure secret uploader. Microsoft
   SQL Server is not currently supported by the installer: the uploader
   validates a PostgreSQL connection URL. Add a SQL Server option only after
   the release owner confirms image support and the installer is updated for
   that database contract.
2. **Entra sign-in:** Create or select an Entra OIDC app registration and
   provide its client ID, issuer URL, and client-secret file. The scripts use
   these values but do not create or edit the app registration. After the first
   apply, add the exact callback URI printed by the script to the app's Web
   redirect URIs.
3. **Azure secrets:** Select an RBAC-enabled Key Vault. The installer uploads
   the local database, licence, and OIDC secret files there; it generates the
   JWT and admin tokens when needed.

## Release assets

The deployment also needs the evaluation licence file and immutable `sha256`
image references for `authz`, `gateway`, `tokensvc`, `web`, and the Emotion
bridge image. Use the release assets supplied for your checkout; these are
inputs consumed by the scripts, not additional Azure services to provision.
If your release checkout includes the public evaluation token at
`keys/token.txt`, pass that path to `--licence-token-file`; the uploader reads
it locally and stores it in Key Vault. Copy the release image digests into the
deployment config.
The service images must be anonymously pullable unless `private_registry` is
configured. Do not substitute tags such as `latest`. The public runtime repo's
example config leaves image digests blank for the release owner to supply.

The optional `private_registry` config stores the registry password in Key
Vault and configures the four service apps to use that secret. All four
service-image hostnames must match `private_registry.server`. The file passed
to `--registry-password-file` must be owner-only. Do not put credentials in
the config file.

### Prepare Neon credentials

The public Neon helper can select an existing project or create a dedicated
development project. Copy its example config, choose the project/database
settings, and validate it:

```sh
cp config/neon.example.json config/neon.json
python3 -B scripts/neon_setup.py --config config/neon.json validate
```

Set `NEON_API_KEY` through a secure environment-variable mechanism. For an
interactive shell, enter it without echoing or placing it in shell history:

```sh
read -r -s -p "Neon API key: " NEON_API_KEY
echo
export NEON_API_KEY
```

For a new project, use exact confirmation matching `project_name`:

```sh
python3 -B scripts/neon_setup.py --config config/neon.json setup \
  --confirm-create "YOUR_CONFIGURED_PROJECT_NAME"
```

For an existing project, use its exact project ID:

```sh
python3 -B scripts/neon_setup.py --config config/neon.json setup \
  --confirm-existing-project "YOUR_CONFIGURED_PROJECT_ID"
```

The helper writes the connection URL to ignored `config/neon-credentials.json`
with owner-only permissions. Do not print or commit it. The Azure secret
uploader requires this file and checks that its PostgreSQL URL requires TLS.
After setup, remove the API key from the shell with `unset NEON_API_KEY`.

## 2. Configure and upload secrets

Copy the example and edit only non-secret deployment settings:

```sh
cp deploy/azure/azure-config.example.json deploy/azure/azure-config.json
```

Set the tenant/subscription UUIDs, Azure region, dedicated resource-group
name, `name_prefix`, Key Vault name/resource group, Neon namespace, OIDC
issuer/client ID, admin email allowlist, and the five image digests. If using
a private registry, set its `server` and `username`. Leave all secret values
out of this file. `deploy/azure/azure-config.json` is gitignored.

Validate the file without contacting Azure:

```sh
python3 -B scripts/deploy_azure.py validate \
  --config deploy/azure/azure-config.json
```

Ensure input files are private. The Neon helper already writes its credential
file with owner-only permissions; set the same mode on the licence,
OIDC-client-secret, and optional registry-password files. Then upload the
values to the configured Key Vault. The helper creates strong JWT and
gateway-admin tokens if those names do not already exist. Existing Key Vault
secrets are preserved, not overwritten. It uses `database-url`,
`licence-token`, `oidc-client-secret`, `jwt-secret`, and
`gateway-admin-token`; private pulls additionally use the configured registry
password secret name. Prefer a dedicated vault. If any of these names already
exist in a shared vault, verify their values through your approved secure
process before deploying.

```sh
chmod 600 /path/to/licence-token /path/to/oidc-client-secret
python3 -B scripts/deploy_azure.py upload-secrets \
  --config deploy/azure/azure-config.json \
  --licence-token-file /path/to/licence-token \
  --oidc-client-secret-file /path/to/oidc-client-secret
```

When using a private service-image registry, add:

```sh
  --registry-password-file /path/to/registry-password
```

The command reads file contents locally and passes file paths (not secret
values) to Azure CLI. It will not rotate an existing secret; update/rotate
secrets through your approved Key Vault process and then restart or revise
the affected apps as required.

## 3. Review and deploy

Select the intended Azure subscription, then run a preview:

```sh
az account set --subscription YOUR_SUBSCRIPTION_ID
python3 -B scripts/deploy_azure.py plan \
  --config deploy/azure/azure-config.json
```

For an existing deployment resource group, `plan` runs Azure Resource Manager
What-If. For a new group it prints the intended resources; the complete
What-If preview runs during `apply`, after the guarded creation of the empty
resource groups and managed identity.

Apply the deployment:

```sh
python3 -B scripts/deploy_azure.py apply \
  --config deploy/azure/azure-config.json
```

The script requires the exact `APPLY <resource-group>` confirmation before
creating resources, and a second exact `DEPLOY <resource-group>` confirmation
after showing What-If output. `authz` uses internal ingress; the other three
apps use external HTTPS ingress. Apps have readiness checks on `/readyz`;
`web` and `authz` start with one minimum replica, while `gateway` and
`tokensvc` can scale to zero.

After deployment, add the printed `https://<web-fqdn>/oidc/callback` URI to
the Entra app registration's Web redirect URIs. The script does not modify
Entra settings. Then run the
[Azure custom API and MCP walkthrough](azure/local-custom-upstream-wizard-test.md)
and verify OIDC, service health, persistence, authorization, and upstream
behavior before accepting traffic.

The script uses Azure Resource Manager deployments scoped to the dedicated
resource group; it does not use Terraform state or provision a remote state
account. If an apply is interrupted after the first confirmation, it may leave
the owned groups, managed identity, and Key Vault role assignment in place.
Rerun `apply` to continue or use `destroy` after reviewing the resources.

## 4. Teardown

Use the same config and Azure tenant/subscription as deployment:

```sh
python3 -B scripts/deploy_azure.py destroy \
  --config deploy/azure/azure-config.json
```

The script verifies the ownership marker on the dedicated application
resource group, lists its resources and any Emotion demo resources, and
requires exact `DESTROY <resource-group>` confirmation. It requests deletion
of the entire dedicated application and Emotion resource groups, so inspect
the complete lists and stop if either group contains anything you need. The
application groups are deleted asynchronously.

The external Key Vault itself, pre-existing secrets, Neon project/database,
Entra app registration, image registry, licence entitlement, and unrelated
resource groups are preserved. Secrets newly uploaded by this script are
tagged with the deployment owner and prefix; destroy deletes only those
tagged secrets. Key Vault soft-delete may keep them recoverable until the
vault's retention period expires. The script removes only this deployment
identity's wrapper-created Key Vault Secrets User assignment; a pre-existing
assignment is retained. Remove the callback URI from a shared Entra app
registration separately if appropriate.

If the Key Vault and its resource group were created solely for this
deployment, remove them separately only after reviewing their remaining
resources and confirming that no pre-existing secrets or other data need to be
kept. Key Vault deletion is subject to soft-delete and purge-protection
retention; do not bypass that retention.

If you created a dedicated Neon project with the Neon helper, inspect the
recorded project ID and remove only that helper-owned project. Set
`NEON_API_KEY` securely as described above before running these commands:

```sh
python3 -B scripts/neon_setup.py --config config/neon.json status
python3 -B scripts/neon_setup.py --config config/neon.json destroy \
  --confirm-project-id THE_REVIEWED_PROJECT_ID
```

The Neon helper refuses to delete an existing project it did not create.
Remove only the deployment-specific callback URI from a shared Entra app
registration; delete a dedicated app registration only if you own it and
have confirmed it is not shared.

For cleanup of resources created by the historical trial, see
[trial status](azure/trial-status.md); those resources are not managed by the
new installer.

## Related Azure material

- [Architecture and enterprise integration](azure/architecture.md)
- [Teardown details and safety checks](azure/teardown.md)
- [Historical implementation plan and acceptance gates](azure/implementation-plan.md)
- [Indicative pricing assumptions](azure/serverless-pricing.md)

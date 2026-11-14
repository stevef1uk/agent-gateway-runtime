# Agent Gateway Azure deployment proposal

This guide describes the low-cost Azure deployment flow shared with the
`agent-gateway` application repository. That repository contains the Azure
Terraform scaffold, guarded lifecycle wrapper, and Key Vault uploader. This
guide and the local Neon helper do not create Azure resources by themselves;
no application resources are applied until the user runs the guarded apply.

For service placement and trade-offs, see the
[Azure architecture](azure/architecture.md). For monthly estimates and
reproducible assumptions, see the
[Azure pricing model](azure/serverless-pricing.md).

## 1. Prepare

Copy `azure-config.example.json` to `azure-config.json` and enter your Azure
tenant ID, subscription ID, and Key Vault name. The local file is ignored by
Git. Keep secrets such as client credentials, Neon API keys, database
passwords, customer keys, and licence tokens out of this config; use the
environment or Key Vault as appropriate.

The estimate uses `francecentral`; update `location` if you choose another
region. Install Azure CLI, authenticate, select the subscription, and register the
`Microsoft.App` and `Microsoft.OperationalInsights` resource providers.
Register `Microsoft.DBforPostgreSQL` only if you explicitly choose Azure
Database for PostgreSQL instead of the default Neon database.

Pin the current licensed image digests. The application repository includes
one public, time-limited demo licence for deployment. Keep vendor private keys
and customer-specific licence files outside Git; a user with a private or
extended licence may pass that file to the uploader. Use Entra ID OIDC for the
web console and configure an administrator allowlist.

The deployment uses a user-created, non-secret Azure config for account,
resource, image, and Key Vault reference values. Neon API keys and database
credentials stay in protected local files or environment-based authentication;
generated runtime secrets are uploaded directly to Key Vault. The uploader
uses the bundled public demo licence by default and verifies its signature and
expiry locally before upload. See the application repository's Azure README
for config validation, required confirmations, and deploy/teardown commands.

Provision or select the non-production Neon database and verify application
persistence and web OIDC-session migrations before creating the Azure
Container Apps environment. The planned script should make Neon project and
database setup repeatable, support an existing Neon project, and avoid printing
credentials. Test migrations against local PostgreSQL first, then run them
against the dedicated Neon development database using TLS. Use a direct Neon
endpoint for schema changes unless pooled-endpoint compatibility is verified;
test the selected runtime endpoint and connection limits separately.

Phase 1 includes a config-driven Neon setup helper. Copy
`config/neon.example.json` to the ignored `config/neon.json`. For an existing
project, set `mode` to `existing`, set its `project_id`, and leave
`project_name` empty. For a new development project, set `mode` to `create`,
leave `project_id` empty, and provide a project name. Validate before
provisioning:

```bash
python3 -B scripts/neon_setup.py --config config/neon.json validate
```

Set `NEON_API_KEY` in the process environment (do not put it in either config
file), then explicitly confirm project creation or mutation of an existing
project:

```bash
read -r -s -p "Neon API key: " NEON_API_KEY
echo
export NEON_API_KEY

# New project (exact confirmation must match project_name):
python3 -B scripts/neon_setup.py --config config/neon.json setup \
  --confirm-create "agent-gateway-development"

# Existing project (exact confirmation must match project_id):
# python3 -B scripts/neon_setup.py --config config/neon.json setup \
#   --confirm-existing-project "YOUR_NEON_PROJECT_ID"
```

The helper creates or selects the configured database and application role,
waits for Neon operations, and stores the connection URL in the ignored
`config/neon-credentials.json` with owner-only permissions. Never print or
commit that file. To upload it and other runtime secrets directly to Key Vault,
use `scripts/azure_secrets.py` from the `agent-gateway` application repository
after preparing that repository's ignored Azure config:

```bash
python3 scripts/azure_secrets.py \
  --config deploy/azure/azure-config.json \
  upload \
  --neon-credentials-file /path/to/agent-gateway-runtime/config/neon-credentials.json
```

The uploader generates JWT/admin secrets locally, reads only the configured
secret names from Key Vault, and transfers values from protected temporary
files using Azure CLI's file upload option. It does not print, download, or
place values in Terraform inputs/state. The user must have Key Vault secret
write permission. Secret names already present are never overwritten by
default; explicit rotation requires `--replace` and a second confirmation.
The one-year demo licence and its public verification key are selected
automatically. To use a private or extended licence, pass
`--licence-token-file /path/to/private-licence` and
`--vendor-public-key-file /path/to/vendor_public.pem`; keep those files
owner-only and out of Git.
The bundled public demo licence expires on **31 December 2027**. The images
enforce that signed expiry; users who need to continue afterwards should
request a private replacement licence. See the
[Pricing page in the main repository](https://github.com/stevef1uk/agent-gateway-demo/blob/main/docs/Pricing.md).
See the application repository's Azure deployment README for details,
including the optional private-registry token file. Entra OIDC uses PKCE and
does not require a client secret.

The `status` command only reports non-secret Neon project metadata.

To delete a project created by this helper and remove its local credentials,
use the exact locally recorded project ID as confirmation:

```bash
python3 -B scripts/neon_setup.py --config config/neon.json status
# Review the project ID shown above before proceeding.
python3 -B scripts/neon_setup.py --config config/neon.json destroy \
  --confirm-project-id "THE_REVIEWED_PROJECT_ID"
```

Destroy refuses to delete projects that are not recorded as created by this
helper. It does not delete or suspend resources in an existing user project.
Review Neon billing and stop/delete those resources separately if you selected
an existing project. Azure resource teardown will be added with the Azure
installer; no Azure resources are currently managed by this branch. Neon
provisioning does not implement Agent Gateway persistence or OIDC sessions;
do not treat it as evidence that database integration is complete.

## 2. Create the Container Apps environment

Create one Consumption-plan Container Apps environment in the selected region.
Use a Log Analytics workspace with deliberate retention and ingestion
monitoring, or another supported logging configuration. The workspace's
ingestion and retention charges are not part of the estimate.

For a low-cost pilot, use the standard managed environment and its built-in
ingress. For production access to private upstreams or a private database,
design the VNet-integrated environment, routes, DNS, and firewall policy
before deployment. The estimate excludes any billed NAT, firewall, private
endpoint, WAF, API Management, or data-transfer resources.

## 3. Deploy the four apps

Create four Container Apps in the same environment, using version-pinned
images. Start with the smallest Consumption sizing supported by the selected
revision (the pricing model assumes `0.25` vCPU and `0.5` GiB per replica):

1. Deploy `authz` first with internal ingress on port `8081`.
2. Deploy `tokensvc` on port `8082` and `gateway` on port `8080`, each with
   external HTTPS ingress. Configure both to reach `authz` using its
   environment-generated internal FQDN.
3. Deploy `web` on port `8083` with external HTTPS ingress. Configure
   `AUTHZ_URL` and `GATEWAY_URL` to use the internal service FQDNs.
4. Configure health checks against each service's `/healthz` endpoint and
   verify that the ingress preserves the request path, authorization, and
   Agent Gateway headers.

Set `gateway`, `tokensvc`, and `authz` replica bounds from local integration
tests, starting with conservative maxima. Do not configure `web` with zero
minimum replicas until the Neon-backed OIDC state/session implementation is in
the deployed image and passes the cold-start callback acceptance test. Until
then, set `web` minimum replicas to one; this mitigates scale-down but does not
survive process restart. Once the Neon session implementation is verified,
`web` can use zero minimum replicas and be tested for scale-down between OIDC
start and callback.

## 4. Configure state, secrets, and identity

Use the existing or installer-created Neon PostgreSQL database by default.
Configure
`PERSISTENCE=postgres` and a TLS-enabled `DATABASE_URL` for the Agent Gateway
services that use PostgreSQL. Use Neon's pooled endpoint for runtime only
after verifying that it is compatible with the selected image's connection
and startup-migration behavior. Restrict connection counts as replicas scale,
and review Neon plan limits, region, backups, retention, and availability.
This proposal assumes the user's existing Neon plan has no additional charge;
Neon pricing, cross-cloud latency and Azure egress are not included.

Implement OIDC transaction state (including nonce and PKCE verifier when used)
and server-side web sessions in that shared Neon database as an early
application/database integration phase. Keep only a protected opaque session
identifier in the browser, expire and clean up records, and consume callback
state atomically to prevent replay. Do not assume that setting `DATABASE_URL`
for domain persistence automatically persists OIDC sessions. Until the new
image passes integration and cold-start callback tests, keep one web replica
warm.

If Azure-managed database hosting is explicitly required, provision Azure
Database for PostgreSQL Flexible Server, create the application database, and
configure the same PostgreSQL persistence settings. Grant network access only
from the Container Apps environment. Schema creation and migration are
handled by the application on startup. The estimate's Burstable configuration
is for non-production testing; production should use a suitably sized General
Purpose tier and availability/backup settings.

Set the same strong `JWT_SECRET` on `authz`, `tokensvc`, and `gateway`. Supply
the customer private key under `/keys` and each service's vendor licence under
`/licences/<service>.token`, read-only. Store these values as Container Apps
secrets or Key Vault references and mount them as secret volumes; do not put
secret values in command history, source files, or deployment logs. If a
secret changes, deploy a new revision or restart the affected revision as
required by Container Apps.

Configure Entra ID OIDC issuer, client ID/secret, callback URL, and the
administrator allowlist using the names and formats supported by the selected
Agent Gateway image release. The exact image configuration is release
specific and must be checked against its accompanying manifest.

Use the generated web callback URL in the Entra app registration and the
matching callback value in the user config. If Azure-specific images need to
be built, suffix release tags with `_a` (for example `<version>_a` and
optionally `latest_a`); deployment config must pin the verified immutable
digest rather than the mutable `latest_a` alias.

Leave `REDIS_URL` unset in the minimum-cost design. Add a managed Redis
service only if its immediate-revocation or decision-cache benefit justifies
its cost and operational scope.

## 5. Verify, monitor, and remove

Before accepting agent traffic:

- Confirm all four `/healthz` endpoints and internal service calls.
- Complete an Entra ID sign-in and callback, then create and revoke a test
  delegation.
- Confirm denied, allowed, and approval-held requests reach the intended
  upstream only through the Gateway PEP.
- Confirm audit records survive a service restart when PostgreSQL is enabled.
- Test scale-to-zero cold starts, configured timeouts, memory/CPU headroom,
  log volume, and outbound network restrictions.
- Set Azure budgets and alerts. Budgets are alerts, not hard spending caps.

Delete the Container Apps and environment, workspace if unused, database,
registry mirror, Key Vault resources, and any network/edge resources created
for the deployment. Retained databases, backups, logs, images, and secrets can
continue to incur charges after application deletion.

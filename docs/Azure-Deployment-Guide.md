# Agent Gateway Azure deployment design and Neon helper

> **Not an installer.** This repository does not include the Agent Gateway
> application source, container build files, Terraform, Azure lifecycle
> commands, or Key Vault secret uploader. An operator verified a development
> trial using tooling not included here; that trial is not production-
> certified. These Azure sections describe design considerations, not
> commands that can deploy or tear down the application from this checkout.

The Neon project setup helper documented below is included here and can be
used independently. Do not treat successful Neon setup as an application
deployment or as proof of application persistence/OIDC behavior. The Azure
deployment outline is retained as reference material until a complete,
reviewed installer and release artifacts are available in this repository.

For service placement and trade-offs, see the
[Azure architecture](azure/architecture.md). For monthly estimates and
reproducible assumptions, see the
[Azure pricing model](azure/serverless-pricing.md).

## 1. Prepare

The root `azure-config.example.json` is a proposal-era example only. No Azure
deployment command in this repository consumes it; copying it does not
configure or deploy an Azure environment. The included Neon helper uses
`config/neon.example.json` instead. Never put client credentials, Neon API
keys, database passwords, customer keys, or licence tokens in either example
config.

The estimate uses `francecentral`; update `location` if you choose another
region. Install Azure CLI, authenticate, select the subscription, and register the
`Microsoft.App` and `Microsoft.OperationalInsights` resource providers.
Register `Microsoft.DBforPostgreSQL` only if you explicitly choose Azure
Database for PostgreSQL instead of the default Neon database.

An installable release requires verified immutable image digests, a supported
licence-delivery workflow, a secret uploader, and a guarded Azure lifecycle
installer. Those release artifacts and tools are not present in this
repository. Do not try to deploy by following the reference sequence below.
Keep any vendor private keys and customer-specific licence files outside Git.

For a future deployment, provision or select a non-production Neon database
and test application persistence and web OIDC-session behavior before Azure
deployment. The local Neon setup helper supports repeatable project/database
setup, selecting an existing project, and ownership-checked teardown without
printing credentials. Test migrations against local PostgreSQL first, then
use TLS against a dedicated Neon development database. Use a direct Neon
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
commit that file. This repository does not include a Key Vault uploader or
deployment config, so it cannot safely transfer the generated credential to
an Azure application. Do not proceed to deployment on the basis of this
helper alone.

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
an existing project. This repository does not include an Azure teardown
runbook or guarded destroy command. Neon provisioning remains separate from
the Agent Gateway application state adapter and does not by itself prove
application persistence or OIDC behavior.

## 2. Azure target design (reference only)

The following sections describe a proposed configuration only; they do not
provide an executable install, upgrade, or teardown procedure. Do not create
billable resources from this outline. A future installer must be published
here and tested before these steps can be used.

The target design uses one Consumption-plan Container Apps environment in the selected region.
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

Set replica bounds from local integration tests, starting with conservative
maxima. The current application image persists shared OIDC/session state in
PostgreSQL and has passed cross-instance integration tests. Keep `web` at one
minimum replica until the deployed Azure image also passes cold-callback and
scale-to-zero acceptance; local database tests alone do not prove that
behavior.

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

# Agent Gateway Azure deployment proposal

This guide describes a proposed, low-cost deployment in Azure. The `azure`
branch currently provides architecture and pricing documentation only; it
does not contain a deployment script or Infrastructure-as-Code, and no Azure
resources are created by reading this guide.

For service placement and trade-offs, see the
[Azure architecture](azure/architecture.md). For monthly estimates and
reproducible assumptions, see the
[Azure pricing model](azure/serverless-pricing.md).

## 1. Prepare

Choose a subscription and region (the estimate uses `francecentral`). Install
Azure CLI, authenticate, select the subscription, and register the
`Microsoft.App` and `Microsoft.OperationalInsights` resource providers.
Register `Microsoft.DBforPostgreSQL` only if you explicitly choose Azure
Database for PostgreSQL instead of the default Neon database.

Obtain the current licensed image tags/digests, customer private key, and
per-service signed licence tokens from the vendor. Keep activation material
outside the repository and restrict access to the Azure operators who need it.
Use Entra ID OIDC for the web console and configure an administrator allowlist.

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

For the lowest-cost default, set all four apps' minimum replicas to zero and
begin with a small maximum while measuring startup, memory, and concurrency.
The web console stores OIDC sign-in session state in process memory, so a
scale-down between sign-in and identity-provider callback can cause the
callback to fail. If dependable console sign-in outweighs idle cost, configure
`web` with one minimum and one maximum replica. A warm replica reduces but
does not eliminate loss on process restart; durable shared web sessions would
require an application change. The target low-cost design is to persist OIDC
state and sessions in Neon and then run `web` with zero minimum replicas; the
current web image does not yet support that session-store configuration.

## 4. Configure state, secrets, and identity

Use the existing Neon PostgreSQL database by default. Configure
`PERSISTENCE=postgres` and a TLS-enabled `DATABASE_URL` for the Agent Gateway
services that use PostgreSQL. Use Neon's pooled endpoint for runtime only
after verifying that it is compatible with the selected image's connection
and startup-migration behavior. Restrict connection counts as replicas scale,
and review Neon plan limits, region, backups, retention, and availability.
This proposal assumes the user's existing Neon plan has no additional charge;
Neon pricing, cross-cloud latency and Azure egress are not included.

The long-term goal is to store the web console's OIDC state and server-side
session in that shared Neon database too, so sign-in can survive scale-to-zero
and replica changes. This needs an application/image change; the current web
image keeps OIDC session state in process memory. Do not assume that setting
`DATABASE_URL` persists web sessions. Until a release supports shared session
storage, keep one web replica warm when reliable sign-in is required, or accept
that a callback after scale-to-zero can fail and require a retry.

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

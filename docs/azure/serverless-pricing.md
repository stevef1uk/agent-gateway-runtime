# Indicative Azure serverless deployment cost estimate

Prepared **13 November 2026** for Azure region **`francecentral` (Paris)**,
USD/month, on-demand, before tax. This is a planning model, not an Azure quote,
a capacity guarantee, or a spending cap. It creates no Azure resources.

The target low-cost shape uses Azure Container Apps Consumption for the four
service containers, with all four able to scale to zero after the Neon-backed
web OIDC session implementation is built and passes its cold-callback tests.
The default durable database assumption is the user's existing Neon PostgreSQL
plan, which adds no Azure database charge in this model. Azure Database for
PostgreSQL Flexible Server is an explicit, separately costed alternative.
Until shared OIDC state/session support is deployed and verified, keep one web
replica warm; the current web image's in-memory state is not safe for
scale-to-zero sign-in.

## 1. Monthly estimates

| Scenario | Container Apps gross, before included grants | After modeled unused Container Apps grants | Default with existing Neon plan (Azure portion) | With Azure PostgreSQL B1ms (gross) |
|---|---:|---:|---:|---:|
| Idle: all apps scaled to zero | $0.00 | $0.00 | $0.00 | $18.13 |
| Light: 10,000 external actions | $0.16 | $0.00 | $0.00 | $18.29 |
| Regular: 100,000 external actions | $1.58 | $0.00 | $0.00 | $19.71 |
| Busy illustration: 1,000,000 external actions | $15.79 | $10.39 | $10.39 | $33.92 |

The default Neon column assumes the user's existing Neon plan covers this
database usage at no additional charge; it is not a general Neon price or a
guarantee that every Neon plan remains free. Check plan limits and actual
billing. Azure outbound data transfer to Neon may also be billable and is
excluded.

The scale-to-zero estimates are conditional on implementing and testing shared
OIDC state/session storage in Neon: **the current web image does not persist
OIDC sessions there**. Until the application release adds that capability,
sign-in state can be lost when `web` scales to zero. The modeled Container Apps
cost is the same after shared-session support is implemented; Neon
compute/storage costs for the added session records and any Neon project/plan
charges are not separately modeled and may affect the user's bill.

The Azure PostgreSQL column adds **$18.13/month** for a single B1ms Burstable
Flexible Server and 32 GB storage. This is an indicative development/staging
configuration, not a production recommendation. Microsoft advises against
Burstable for production. A minimal illustrative 2-vCore General Purpose
server at the same region's retail rate adds about **$154.64/month** including
32 GB storage.

The target Container Apps estimates assume every app has a zero minimum
replica and model only active compute/request usage for the gateway/authz/token
service hop pattern. Until Neon-backed OIDC session support passes acceptance,
the web minimum must be one; that warm replica adds approximately
**$5.91/month** at modeled idle rates. “After modeled unused grants” assumes
that none of the subscription's free grants have been consumed elsewhere.
Actual billing depends on subscription-level usage and traffic.

### Web session options and cost

| Web session design | Can `web` scale to zero reliably for OIDC? | Modeled added Azure cost |
|---|---|---:|
| Current image: in-memory OIDC session | No; a callback after scale-to-zero/restart may fail | $0 when scaled to zero; optional warm replica adds about $5.91/month |
| Target: shared OIDC session/state stored in Neon | Yes, after the web app/image adds and validates shared session storage | $0 Azure database cost under the existing-Neon assumption; possible additional Neon compute/storage and Azure egress are unpriced |
| Alternative: shared session storage in Azure Database for PostgreSQL | Yes, after the same application support is added | Add the PostgreSQL Flexible Server cost shown above; the small B1ms illustration adds about $18.13/month before networking/egress |

Using Neon for Agent Gateway's existing domain persistence alone does not
enable the target session design. No available Azure-native serverless
key/value service is assumed to be compatible with the current web image's
session implementation; adopting one would also require explicit application
storage support and a new estimate.

## 2. Scope and assumptions

| Input | Estimate |
|---|---|
| Region, currency, billing month | `francecentral`, USD, 730 hours |
| Container Apps plan | Consumption, one environment; no Dedicated profile |
| Container size | `0.25` vCPU and `0.5` GiB per replica |
| Always-on allocation | None in the low-cost default; optional `web` minimum replica adds about $5.91/month |
| Target scale-to-zero services | `web`, `gateway`, `tokensvc`, `authz`; zero minimum replicas after Neon-backed web OIDC sessions pass acceptance (until then web minimum is one) |
| Request work model | 2.1 one-second container hops per external action: gateway + authz per action and one tokensvc call per 10 actions |
| Free grants | 180,000 vCPU-seconds, 360,000 GiB-seconds, and 2 million requests per subscription/month |
| Default database assumption | Existing user Neon plan, modeled as $0 additional database cost for this user; Azure egress excluded |
| Azure PostgreSQL test option | One non-HA 1-vCore B1ms Burstable Flexible Server, 32 GB storage, always running |
| Azure PostgreSQL production illustration | One non-HA 2-vCore General Purpose Flexible Server, 32 GB storage |
| Included | Container Apps active compute and request charges, optional Azure PostgreSQL compute/storage when selected |
| Excluded | Neon charges beyond the user's assumed existing plan, Log Analytics ingestion/retention, internet egress (including Azure-to-Neon), private networking/NAT/firewall, WAF/Front Door/API Management, Redis, Key Vault operations, ACR, HA/zone redundancy, support, software licence, and tax |

The model assigns one second of billed work to each hop. Actual gateway time
includes waiting for upstream services and may be much longer; the cost
increases with billed duration. Web-console traffic, post-request scale-down
idle time, and cold-start warm-up are not separately modeled. No load test or
Azure deployment has validated these sizing assumptions. Public Docker Hub
images avoid ACR charges in this estimate.

## 3. Estimate inputs

The [pricing input snapshot](serverless-pricing-inputs.json) records the
regional rates and workload inputs used for these estimates. Refresh and
recalculate from the current Azure Retail Prices API before using the figures
for a purchase or production budget. The inputs are documentation, not an
automated calculator.

## 4. Price sources

The snapshot records the queried rates for France Central on the preparation
date:

- [Azure Container Apps Consumption pricing](https://azure.microsoft.com/pricing/details/container-apps/)
- [Azure Database for PostgreSQL Flexible Server pricing](https://azure.microsoft.com/pricing/details/postgresql/flexible-server/)
- [Azure Retail Prices API — Container Apps, France Central](https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&%24filter=serviceName%20eq%20%27Azure%20Container%20Apps%27%20and%20armRegionName%20eq%20%27francecentral%27)
- [Azure Retail Prices API — PostgreSQL, France Central](https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&%24filter=serviceName%20eq%20%27Azure%20Database%20for%20PostgreSQL%27%20and%20armRegionName%20eq%20%27francecentral%27)
- [Container Apps billing and free grants](https://learn.microsoft.com/azure/container-apps/billing)
- [PostgreSQL compute tiers and Burstable guidance](https://learn.microsoft.com/azure/postgresql/compute-storage/concepts-compute)
- [Neon connection pooling](https://neon.com/docs/connect/connection-pooling)
- [Neon connection strings](https://neon.com/docs/connect/connect-from-any-app)

## 5. Cost controls

- Keep all minimum replicas at zero for minimum cost. Set web minimum to one
  if OIDC sign-in reliability is more important than its idle replica charge;
  shared durable session storage would require an application change.
- Set conservative maximum replicas and request/concurrency limits; review
  scale and logs after a representative test.
- Avoid always-on Redis, Front Door, API Management, ACR, and Dedicated
  Container Apps profiles unless an explicit requirement justifies them.
- Do not mistake a budget alert for a hard limit. Monitor the actual Azure
  Cost Management bill and review retained database, backup, log, and image
  data after teardown.

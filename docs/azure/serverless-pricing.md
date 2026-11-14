# Indicative Azure serverless deployment cost estimate

> **Indicative monthly planning model.** These scenarios help estimate Azure
> costs for the public installer; they are not an Azure quote. Refresh regional
> prices and compare actual usage after deployment.

Prepared **13 November 2026** for Azure region **`francecentral` (Paris)**,
USD/month, on-demand, before tax. This is a planning model, not an Azure quote,
a capacity guarantee, or a spending cap. It creates no Azure resources.

The public installer uses Azure Container Apps Consumption for four service
containers. It keeps `web` and `authz` at one minimum replica each; `gateway`
and `tokensvc` can scale to zero. The estimate includes approximately
$11.82/month for those two idle replicas at the model's rates. The default
durable database assumption is the user's existing Neon PostgreSQL plan,
which adds no Azure database charge in this model. Azure Database for
PostgreSQL Flexible Server is an explicit, separately costed alternative.
Keep `web` warm until the exact image intended for deployment passes OIDC
cold-callback and restart acceptance; shared database state alone does not
prove Azure scale-to-zero behavior.

## 1. Monthly estimates

| Scenario | Container Apps gross, before included grants | After modeled unused Container Apps grants | Default with existing Neon plan (Azure portion) | With Azure PostgreSQL B1ms (gross) |
|---|---:|---:|---:|---:|
| Idle: no external actions; web and authz warm | $11.82 | $11.82 | $11.82 | $29.95 |
| Light: 10,000 external actions | $11.98 | $11.82 | $11.82 | $30.11 |
| Regular: 100,000 external actions | $13.40 | $11.82 | $11.82 | $31.53 |
| Busy illustration: 1,000,000 external actions | $27.61 | $22.21 | $22.21 | $45.74 |

The default Neon column assumes the user's existing Neon plan covers this
database usage at no additional charge; it is not a general Neon price or a
guarantee that every Neon plan remains free. Check plan limits and actual
billing. Azure outbound data transfer to Neon may also be billable and is
excluded.

The trial application used shared PostgreSQL-backed OIDC state/session storage,
and cross-instance tests passed. The trial did not complete Azure callback
acceptance after scale-to-zero, so the model keeps one `web` replica warm
until that behavior is verified in the exact deployed release. Neon
compute/storage costs for session records and any Neon project/plan charges
are not separately modeled and may affect the user's bill.

The Azure PostgreSQL column adds **$18.13/month** for a single B1ms Burstable
Flexible Server and 32 GB storage. This is an indicative development/staging
configuration, not a production recommendation. Microsoft advises against
Burstable for production. A minimal illustrative 2-vCore General Purpose
server at the same region's retail rate adds about **$154.64/month** including
32 GB storage.

The deployment baseline includes one warm `web` and one warm `authz` replica;
each adds approximately **$5.91/month** at modeled idle rates. The idle
scenario is therefore not a zero-cost/all-scaled-down deployment.
“After modeled unused grants” assumes that none of the subscription's free
grants have been consumed elsewhere.
Actual billing depends on subscription-level usage and traffic.

### Web session options and cost

| Web session design | Can `web` scale to zero reliably for OIDC? | Modeled added Azure cost |
|---|---|---:|
| Trial application: shared PostgreSQL OIDC state/session | Cross-instance tests passed; Azure scale-to-zero callback behavior was not verified | Keep a warm replica pending acceptance; about $5.91/month at modeled idle rates |
| Shared OIDC state/session plus verified Azure cold callback | Candidate for scale-to-zero only after testing the exact deployed image | $0 Azure database cost under the existing-Neon assumption; possible additional Neon compute/storage and Azure egress are unpriced |
| Alternative: shared session storage in Azure Database for PostgreSQL | Requires application support and the same Azure cold-callback acceptance | Add the PostgreSQL Flexible Server cost shown above; the small B1ms illustration adds about $18.13/month before networking/egress |

Shared database support is necessary but does not, by itself, prove
scale-to-zero callback reliability. No available Azure-native serverless
key/value service is assumed in this model; adopting another store requires
explicit application support and a new estimate.

## 2. Scope and assumptions

| Input | Estimate |
|---|---|
| Region, currency, billing month | `francecentral`, USD, 730 hours |
| Container Apps plan | Consumption, one environment; no Dedicated profile |
| Container size | `0.25` vCPU and `0.5` GiB per replica |
| Always-on allocation | One `web` and one `authz` minimum replica; about $11.82/month at modeled idle rates |
| Target scale-to-zero services | `gateway` and `tokensvc`; `web` remains warm pending cold-callback acceptance and `authz` remains warm in the current template |
| Request work model | 2.1 one-second container hops per external action: gateway + authz per action and one tokensvc call per 10 actions |
| Free grants | 180,000 vCPU-seconds, 360,000 GiB-seconds, and 2 million requests per subscription/month |
| Default database assumption | Existing user Neon plan, modeled as $0 additional database cost for this user; Azure egress excluded |
| Azure PostgreSQL test option | One non-HA 1-vCore B1ms Burstable Flexible Server, 32 GB storage, always running |
| Azure PostgreSQL production illustration | One non-HA 2-vCore General Purpose Flexible Server, 32 GB storage |
| Included | Container Apps active compute and request charges, optional Azure PostgreSQL compute/storage when selected |
| Excluded | Neon charges beyond the user's assumed existing plan, Azure Monitor log ingestion/retention, internet egress (including Azure-to-Neon), private networking/NAT/firewall, WAF/Front Door/API Management, Redis, Key Vault operations, private registry costs, HA/zone redundancy, support, software licence, and tax |

The model assigns one second of billed work to each hop. Actual gateway time
includes waiting for upstream services and may be much longer; the cost
increases with billed duration. Web-console traffic, post-request scale-down
idle time, and cold-start warm-up are not separately modeled. No load test or
Azure deployment has validated these sizing assumptions. Publicly pullable
images avoid registry charges; private image registries add their own costs.

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

- The installer keeps `web` and `authz` at one minimum replica. Change these
  bounds only after validating cold-start, OIDC, and service dependencies.
- Set conservative maximum replicas and request/concurrency limits; review
  scale and logs after a representative test.
- Avoid always-on Redis, Front Door, API Management, ACR, and Dedicated
  Container Apps profiles unless an explicit requirement justifies them.
- Do not mistake a budget alert for a hard limit. Monitor the actual Azure
  Cost Management bill and review retained database, backup, log, and image
  data after teardown.

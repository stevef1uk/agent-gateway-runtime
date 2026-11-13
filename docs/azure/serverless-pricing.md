# Indicative Azure serverless deployment cost estimate

Prepared **13 November 2026** for Azure region **`francecentral` (Paris)**,
USD/month, on-demand, before tax. This is a planning model, not an Azure quote,
a capacity guarantee, or a spending cap. It creates no Azure resources.

The recommended low-cost shape uses Azure Container Apps Consumption for the
four existing service containers. The web console has one minimum replica
because its OIDC session state is in memory; gateway, tokensvc, and authz can
scale to zero. A small Flexible Server database is shown separately because
durable persistence has an always-on cost and is not serverless.

## 1. Monthly estimates

| Scenario | Container Apps gross, before included grants | Container Apps estimate, unused grants applied | Gross with non-HA PostgreSQL B1ms test database |
|---|---:|---:|---:|
| Idle: one idle web replica | $5.91 | $5.91 | $24.04 |
| Light: 10,000 external actions | $6.07 | $5.91 | $24.20 |
| Regular: 100,000 external actions | $7.49 | $5.91 | $25.61 |
| Busy illustration: 1,000,000 external actions | $21.70 | $16.30 | $39.83 |

The PostgreSQL column adds **$18.13/month** for a single B1ms Burstable
Flexible Server and 32 GB storage. It is an indicative development/staging
configuration, not a production recommendation. Microsoft advises against
Burstable for production. A minimal illustrative 2-vCore General Purpose
server at the same region's retail rate adds about **$154.64/month** including
32 GB storage, putting the idle baseline near **$160.55/month** before traffic,
logs, networking, and production availability settings.

The Container Apps estimates include its always-idle web replica and modeled
active compute/request usage. “Unused grants applied” assumes no other
workload has consumed the subscription-level free grants; to avoid
underestimating the bill, that column applies grants only to modeled active
usage and requests, not to the web replica's idle allocation. Actual billing
can be lower or higher depending on grant use and your subscription.

## 2. Scope and assumptions

| Input | Estimate |
|---|---|
| Region, currency, billing month | `francecentral`, USD, 730 hours |
| Container Apps plan | Consumption, one environment; no Dedicated profile |
| Container size | `0.25` vCPU and `0.5` GiB per replica |
| Always-on allocation | `web`: one minimum replica, billed at idle rates |
| Scale-to-zero services | `gateway`, `tokensvc`, `authz`; zero minimum replicas |
| Request work model | 2.1 one-second container hops per external action: gateway + authz per action and one tokensvc call per 10 actions |
| Free grants | 180,000 vCPU-seconds, 360,000 GiB-seconds, and 2 million requests per subscription/month |
| PostgreSQL test option | One non-HA 1-vCore B1ms Burstable Flexible Server, 32 GB storage, always running |
| PostgreSQL production illustration | One non-HA 2-vCore General Purpose Flexible Server, 32 GB storage |
| Included | Container Apps active/idle compute, request charges, listed PostgreSQL compute/storage |
| Excluded | Log Analytics ingestion/retention, internet egress, private networking/NAT/firewall, WAF/Front Door/API Management, Redis, Key Vault operations, ACR, HA/zone redundancy, support, software licence, and tax |

The model assigns one second of billed work to each hop. Actual gateway time
includes waiting for upstream services and may be much longer; the cost
increases with billed duration. No load test or Azure deployment has validated
these sizing assumptions. Public Docker Hub images avoid ACR charges in this
estimate.

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

## 5. Cost controls

- Keep minimum replicas at zero except the web replica needed for its current
  in-memory sign-in session design.
- Set conservative maximum replicas and request/concurrency limits; review
  scale and logs after a representative test.
- Avoid always-on Redis, Front Door, API Management, ACR, and Dedicated
  Container Apps profiles unless an explicit requirement justifies them.
- Do not mistake a budget alert for a hard limit. Monitor the actual Azure
  Cost Management bill and review retained database, backup, log, and image
  data after teardown.

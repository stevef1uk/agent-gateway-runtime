# Indicative GCP serverless deployment cost estimate

Prepared 9 November 2026 for the published-image customer deployment in region **`europe-west9` (Paris)**, a Cloud Run Tier 1 region. USD/month, on-demand, excluding tax. **Nothing is deployed by this estimate.** This is a planning model, not a quote or spending cap; actual charges depend on region, usage, data retention, network traffic, current prices, and billing-account credits.

This model prices the GCP serverless control plane:
- **Consolidated 2-service Cloud Run control plane** (`web_g` + unified `gateway_g` embedding `authz` and `tokensvc`), requiring an average of **`1.5` Cloud Run hops per external action** (1 hop for direct agent API/MCP calls, 2 hops for console-initiated flows) and **1 GB of Artifact Registry storage** (2 plain-binary images with signed-licence verification).
- **Cloud Run `1.0 vCPU` + `512 MiB` with multi-request concurrency (`concurrency = 80`, `min_instance_count = 0`)**, sharing vCPU allocation across overlapping I/O-bound requests (`1.5x` effective overlap in Light testing, `2.0x` in Regular testing, `4.0x` in Busy illustration; plus a conservative `1.0x` zero-overlap column for reference).
- **Deployment shape:** the runtime deploy script creates the two core Cloud Run services, mirrors their images into Artifact Registry, and uses Firestore, Secret Manager, and Cloud Storage.

The model is indicative rather than an exact bill for every runtime deployment. It includes a sample 7-day Firestore PITR allowance, but the runtime deploy script does not currently enable PITR. Free-tier allowances are generally applied at billing-account scope and can be shared with other projects. Optional Emotion, Vertex AI model usage, and one-time Cloud Build image-mirroring costs are not included.

## 1. Monthly cost summary (`europe-west9` Paris)

*(Includes `_g` image registry storage, one signed-licence GCS GET per cold service start, and a conservative +2s activation-duration budget; no image decryption is included.)*

| Monthly Scenario | Gross (zero overlap `1.0x`) | **Gross (with concurrency)** | **Net (after modeled GCP free-tier allowances)** |
| --- | ---: | ---: | ---: |
| **Idle** (retained data + registry + secrets) | $0.28 | **$0.28** | **$0.09** |
| **Light testing** (10,000 external actions, 1s mean) | $1.14 | **$1.02** | **$0.24** |
| **Regular testing** (100,000 external actions, 1s mean) | $8.88 | **$6.98** | **$2.47** |
| **Regular testing, slow tools** (100,000 actions, 5s mean) | $24.03 | **$14.56** | **$10.05** |
| **Busy illustration** (1,000,000 external actions, 1s mean) | $82.90 | **$54.47** | **$37.51** |

> [!TIP]
> Consolidating `authz` + `tokensvc` into `gateway` reduces 100,000 external actions to **150,000 Cloud Run calls** (and **75,000 vCPU-seconds** at 1s mean with 2x concurrency). The model applies the standard monthly Cloud Run allowances of **180,000 vCPU-seconds, 360,000 GiB-seconds, and 2,000,000 requests**; actual remaining allowance depends on other usage under the billing account.

The model suggests budgeting above its estimates to allow for unmodeled services and usage. Set a billing budget and alert in Google Cloud; a budget alert is not a spending cap.

## 2. Detailed monthly component breakdown

### A. Gross on-demand rates (no free tier applied, 1s base mean, `1.0 vCPU` + `512 MiB`)

| Component | Idle | Light testing (10k) | Regular testing (100k) | Busy illustration (1M) |
| --- | ---: | ---: | ---: | ---: |
| Cloud Run CPU + Memory (`1.5` hops/action) | $0.00 | $0.25 | $1.89 | $9.47 |
| Cloud Run requests (`1.5` hops/action) | $0.00 | $0.01 | $0.06 | $0.60 |
| Built-in Cloud Run HTTPS + IAM ingress | $0.00 | $0.00 | $0.00 | $0.00 |
| Firestore reads & writes (20R + 10W/action) | $0.00 | $0.18 | $1.80 | $18.00 |
| Firestore storage | $0.02 | $0.05 | $0.36 | $1.80 |
| Firestore PITR (7-day window) | $0.02 | $0.05 | $0.36 | $1.80 |
| Cloud Logging (ingestion + 30d retention) | $0.00 | $0.13 | $1.00 | $10.00 |
| Secret Manager (2 active secrets + access) | $0.12 | $0.12 | $0.14 | $0.27 |
| Cloud Storage (activation objects + ops) | $0.02 | $0.02 | $0.04 | $0.11 |
| Google OIDC provider (charges not modelled) | $0.00 | $0.00 | $0.00 | $0.00 |
| Internet data transfer (Standard Tier) | $0.00 | $0.09 | $0.85 | $8.50 |
| Artifact Registry storage (1 GB for 2 `_g` images) | $0.10 | $0.10 | $0.10 | $0.10 |
| Signed licence GCS GET + cold-start CPU/Mem (5% cold) | $0.00 | $0.04 | $0.38 | $3.82 |
| **Total Gross (before free tier)** | **$0.28** | **$1.02** | **$6.98** | **$54.47** |

Totals use unrounded amounts; displayed component rows are rounded.

### B. Net estimated bill (with modeled GCP free-tier allowances applied)

| Component | Idle | Light testing (10k) | Regular testing (100k) | Busy illustration (1M) |
| --- | ---: | ---: | ---: | ---: |
| Cloud Run CPU + Memory (first 180k vCPU-s & 360k GiB-s free) | $0.00 | $0.00 | $0.00 | $4.68 |
| Cloud Run requests (first 2M requests/mo free) | $0.00 | $0.00 | $0.00 | $0.00 |
| Firestore reads & writes (first 1.5M R & 600k W/mo free) | $0.00 | $0.00 | $0.61 | $16.81 |
| Firestore storage (first 1 GiB free) | $0.00 | $0.00 | $0.18 | $1.62 |
| Firestore PITR (7-day window) | $0.02 | $0.05 | $0.36 | $1.80 |
| Cloud Logging (first 50 GiB/mo free) | $0.00 | $0.00 | $0.00 | $0.00 |
| Secret Manager (first 6 versions & 10k accesses free) | $0.00 | $0.00 | $0.00 | $0.12 |
| Cloud Storage (activation objects + ops) | $0.02 | $0.02 | $0.04 | $0.11 |
| Google OIDC provider (charges not modelled) | $0.00 | $0.00 | $0.00 | $0.00 |
| Internet data transfer (Standard Tier) | $0.00 | $0.09 | $0.85 | $8.50 |
| Artifact Registry storage (first 0.5 GB free) | $0.05 | $0.05 | $0.05 | $0.05 |
| Signed licence GCS GET + cold-start activation | $0.00 | $0.04 | $0.38 | $3.82 |
| **Total Net (after GCP Free Tier)** | **$0.09** | **$0.24** | **$2.47** | **$37.51** |

## 3. Usage assumptions

| Input | Idle | Light testing | Regular testing | Busy illustration |
| --- | ---: | ---: | ---: | ---: |
| External requests/month | 0 | 10,000 | 100,000 | 1,000,000 |
| Average billed seconds per hop | 1 | 1 | 1 | 1 |
| Average Cloud Run hops per external action | 1.5 | 1.5 | 1.5 | 1.5 |
| Effective concurrent requests sharing 1 vCPU | 1.0 | 1.5 | 2.0 | 4.0 |
| Firestore data GiB-month | 0.1 | 0.25 | 2 | 10 |
| Firestore PITR GiB-month | 0.1 | 0.25 | 2 | 10 |
| Cloud Logging GiB ingested/month | 0 | 0.25 | 2 | 20 |
| Internet egress GB/month | 0 | 1 | 10 | 100 |
| GCS activation storage GB-month | 1 | 1 | 2 | 5 |
| OIDC active users/month (provider charges not modelled) | 0 | 5 | 10 | 100 |

## 4. Slow-tool sensitivity (1s vs 5s mean invocation duration)

| Scenario | Gross, zero overlap `1.0x` (1s / 5s) | **Gross, with concurrency (1s / 5s)** | **Net after Free Tier (1s / 5s)** |
| --- | ---: | ---: | ---: |
| **10,000 external actions** | $1.14 / $2.65 | **$1.02 / $2.03** | **$0.24 / $0.24** |
| **100,000 external actions** | $8.88 / $24.03 | **$6.98 / $14.56** | **$2.47 / $10.05** |
| **1,000,000 external actions** | $82.90 / $234.46 | **$54.47 / $130.22** | **$37.51 / $118.39** |

## 5. Reproduce the estimates offline

```sh
# Gross consolidated estimate (1.5 hops, 1.0 vCPU with concurrency, 1 GB registry)
python3 -B scripts/estimate-gcp-serverless.py --images

# 5-second slow-tool sensitivity
python3 -B scripts/estimate-gcp-serverless.py --images --average-seconds 5

# Zero concurrency overlap (worst-case 1 request per active container)
python3 -B scripts/estimate-gcp-serverless.py --images --concurrency 1.0

# Net estimate with GCP monthly project free tier applied
python3 -B scripts/estimate-gcp-serverless.py --images --apply-free-tier
```

See [serverless-pricing-inputs.json](serverless-pricing-inputs.json) for all rate dimensions, free-tier allowances, and scenario inputs.

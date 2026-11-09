# Agent Gateway — GCP deployment

The **`gcp` branch** deploys Agent Gateway into your own Google Cloud Platform (GCP) project using published encrypted container images and **Terraform**. Application source and a Go compiler are not required. The `main` branch contains the separate local/container demos.

## Target Serverless Architecture (`europe-west9` Paris)

- **Consolidated Cloud Run v2 Services (`web` and `gateway`)**: Scale-to-zero (`min_instance_count = 0`), `1.0 vCPU`, `512 MiB`, `concurrency = 80`, with `authz` and `tokensvc` consolidated into `gateway`.
- **Firestore Native State**: Strongly consistent document storage and ACID transactions for delegations, approvals, audit, signups, OAuth sessions and DPoP replay/revocation, with 7-day Point-in-Time Recovery (PITR).
- **Google Cloud Identity Platform**: OIDC + S256 PKCE human authentication.
- **Artifact Registry & Cloud Storage Activation**: Encrypted container images activated at cold start using pinned Cloud Storage object generations.
- **Vertex AI Policy Wizard**: Powered by `gemini-2.5-flash-lite` in `europe-west9`.
- **Optional Compute Engine Forward Proxy (`e2-micro`)**: Single-instance proxy accessed locally via Cloud IAP TCP forwarding (`gcloud compute start-iap-tunnel`).

```bash
git clone --branch gcp https://github.com/stevef1uk/agent-gateway-runtime.git
cd agent-gateway-runtime
```

*(Terraform deployment modules and customer runtime scripts for the `gcp` branch are under construction.)*

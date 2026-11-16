# Agent Gateway — GCP deployment

The **`gcp` branch** deploys Agent Gateway into your own Google Cloud Platform (GCP) project using published container images with signed-licence verification. Application source, Terraform, Docker, and a Go compiler are not required for customer deployment. See the [GCP demo guide](docs/GCP-Demos.md) for the configured routes, live weather walkthrough, and compatibility with the `main` demos. The `main` branch contains separate local/container demos.

**Sign GCP images:** In GitHub Actions, run **Sign GCP release images** with the `gcp` branch selected. Enter the exact published image tag used for deployment (do not use `latest`); optionally select Emotion. The workflow resolves and signs the existing image digests without rebuilding them, and lists the signed references in its summary. Set repository Actions secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` first. Verify with Cosign identity `https://github.com/stevef1uk/agent-gateway-runtime/.github/workflows/sign-gcp-images.yml@refs/heads/gcp` and issuer `https://token.actions.githubusercontent.com`. This adds image signatures only—not an SBOM or provenance. See [image verification guidance](https://github.com/stevef1uk/agent-gateway-runtime/blob/main/docs/Container-Image-Security.md).

```bash
IMAGE='<exact immutable image reference from the workflow summary>'
cosign verify \
  --certificate-identity 'https://github.com/stevef1uk/agent-gateway-runtime/.github/workflows/sign-gcp-images.yml@refs/heads/gcp' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  "$IMAGE"
```

## Target Serverless Architecture (`europe-west9` Paris)

- **Consolidated Cloud Run v2 Services (`web` and `gateway`)**: Scale-to-zero (`min_instance_count = 0`), `1.0 vCPU`, `512 MiB`, `concurrency = 80`, with `authz` and `tokensvc` consolidated into `gateway`.
- **Firestore Native State**: Shared document storage for sessions, delegations, approvals, audit state, and replay protection.
- **Google OIDC**: Optional browser sign-in configured with a Google OAuth client.
- **Artifact Registry & Cloud Storage Activation**: the deploy script mirrors the published images into Artifact Registry; Cloud Run fetches the signed licence token from a private Cloud Storage bucket.
- **Vertex AI Policy Wizard**: Powered by `gemini-2.5-flash-lite` in `europe-west9`.

```bash
git clone --branch gcp https://github.com/stevef1uk/agent-gateway-runtime.git
cd agent-gateway-runtime
```

See the [GCP documentation index](docs/gcp/README.md), [deployment guide](docs/GCP-Deployment-Guide.md), [architecture overview](docs/gcp/architecture.md), and [pricing estimate](docs/gcp/serverless-pricing.md). The GCP deploy script defaults gateway and web to `min=0`; first requests after idle may incur a cold start.

## Public evaluation licence expiry

The public evaluation licence in `keys/token.txt` expires on
**31 December 2027**. The images enforce this signed expiry. To keep running
after that date, request a private replacement licence from the vendor. See
the [Pricing page in the main repository](https://github.com/stevef1uk/agent-gateway-demo/blob/main/docs/Pricing.md)
for licensing details.

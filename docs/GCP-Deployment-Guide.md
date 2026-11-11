# Agent Gateway GCP Deployment

This guide deploys the published signed-licence Agent Gateway images into your own Google Cloud project. You do not need the Agent Gateway application source, Go, Terraform, or Docker.

For an overview of the deployed services and request flow, see the [GCP architecture](gcp/architecture.md). For indicative operating costs, see the [GCP pricing estimate](gcp/serverless-pricing.md).

## What you need

- A Google Cloud project with billing enabled.
- `gcloud` installed and authenticated with `gcloud auth login` and `gcloud auth application-default login`.
- This repository contains deliberately public **evaluation-only** activation material. `keys/token.txt` is used by the four Agent Gateway service images. `keys/customer_private.pem` is required only when deploying the separate Emotion backend with `--emotion`.

Do not reuse these evaluation files for production or paid/customer deployments. The deployment script uploads the signed licence token to a private Cloud Storage bucket. It uploads the evaluation customer key only for the optional Emotion backend.

## 1. Prepare the project

```bash
git clone --branch gcp https://github.com/stevef1uk/agent-gateway-runtime.git
cd agent-gateway-runtime

export GCP_PROJECT_ID="test2-514309"  # change this to your project ID

gcloud auth login
gcloud auth application-default login
gcloud config set project "$GCP_PROJECT_ID"
```

Verify the project and billing link before deployment:

```bash
gcloud projects describe "$GCP_PROJECT_ID"
gcloud billing projects describe "$GCP_PROJECT_ID"
```

If billing is not linked:

```bash
gcloud billing accounts list
gcloud billing projects link "$GCP_PROJECT_ID" \
  --billing-account=YOUR_OPEN_BILLING_ACCOUNT_ID
```

The deploying account needs permission to enable APIs, create service accounts, grant IAM roles, create secrets and buckets, create Firestore, and deploy Cloud Run. For a disposable development project, Project Owner or Editor is sufficient. Check the active account:

```bash
gcloud auth list
gcloud config get-value account
```

## 2. Deploy

Run a validation-only pass first:

```bash
scripts/deploy-gcp.sh \
  --project-id "$GCP_PROJECT_ID" \
  --version latest \
  --keys-directory keys
```

Then deploy:

```bash
scripts/deploy-gcp.sh \
  --project-id "$GCP_PROJECT_ID" \
  --version latest \
  --keys-directory keys \
  --emotion \
  --apply
```

The script enables APIs, creates Firestore, service accounts, Secret Manager secrets, the activation bucket, and the two Cloud Run services. It mirrors the public Docker Hub images into your project’s Artifact Registry with Cloud Build, then deploys Cloud Run from that private project registry. The main services fetch and verify only the signed licence token; the customer key is not mounted into them. Docker is not required on the customer machine.

```text
stevef1uk/agent-gateway-gateway_g:VERSION
stevef1uk/agent-gateway-web_g:VERSION
```

The `latest` tag is updated whenever a new GCP image release is published. Each deployment copies the current `latest` images into your Artifact Registry and deploys them. The current published release is `2026-11-11-gcp-fa519a3`; for repeatable deployments or rollback, replace `latest` with that exact immutable release tag.

## Google Sign-In

Google sign-in is a required **second step**. If the first deployment did not include `--oidc-client-id` and `--oidc-client-secret`, the console deliberately displays:

```json
{"error":"oidc is not enabled; unset OIDC_ISSUER_URL to use dev mode"}
```

That means the infrastructure is deployed, but browser sign-in has not been configured yet.

The account creating the OAuth client needs project visibility plus OAuth configuration permissions. Check the active account:

```bash
gcloud auth list
gcloud config get-value account
```

If necessary, a project administrator can grant the roles:

```bash
ACCOUNT="$(gcloud config get-value account)"

gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="user:$ACCOUNT" \
  --role="roles/viewer"

gcloud projects add-iam-policy-binding "$GCP_PROJECT_ID" \
  --member="user:$ACCOUNT" \
  --role="roles/oauthconfig.editor"
```

`roles/oauthconfig.editor` permits creating OAuth clients and secrets, managing test users, and updating OAuth consent configuration. If these commands are denied, ask the organization or project administrator to grant the roles.

Create a Google OAuth web client in **APIs & Services -> Credentials**. After the script prints the web URL, add this redirect URI to the OAuth client:

```text
https://WEB_CLOUD_RUN_HOST/oidc/callback
```

Then redeploy with the client ID and secret file:

```bash
scripts/deploy-gcp.sh \
  --project-id "$GCP_PROJECT_ID" \
  --version latest \
  --keys-directory keys \
  --oidc-client-id YOUR_CLIENT_ID.apps.googleusercontent.com \
  --oidc-client-secret /secure/path/to/client-secret.txt \
  --apply
```

Alternatively, enter the secret interactively without putting it in shell history:

```bash
read -r -s -p "Google OAuth client secret: " GCP_OIDC_CLIENT_SECRET
echo
export GCP_OIDC_CLIENT_SECRET

scripts/deploy-gcp.sh \
  --project-id "$GCP_PROJECT_ID" \
  --version latest \
  --keys-directory keys \
  --oidc-client-id YOUR_CLIENT_ID.apps.googleusercontent.com \
  --apply
unset GCP_OIDC_CLIENT_SECRET
```

The client secret is stored in Secret Manager. Google may show an unverified-app warning while the OAuth app is in testing; add your account as a test user.

## Verify

Use the URLs printed by the script:

```bash
curl -i https://WEB_CLOUD_RUN_HOST/healthz
curl -i https://GATEWAY_CLOUD_RUN_HOST/healthz
```

The serverless profile uses Firestore for sessions, delegations, approvals, audit state, and replay protection. Backup/Restore and Kubernetes-only features are intentionally hidden.

### Demonstrate a protected weather API

The GCP weather API is reached through the public **web Console URL**, which proxies governed calls to the private Gateway. Do not give an agent the private Gateway URL or the Open-Meteo upstream URL.

1. Sign in to the Console and open the API Wizard.
2. Create a delegation for `/v1/forecast` and `/v1/elevation` with the `read` action. Add an approval rule for `read` on `/v1/elevation` if you want to exercise the approval flow.
3. Keep the one-time delegation secret secure. The Wizard’s **Token** tab provides the GCP refresh command at `/api/agent/token`; it requires the delegation ID and secret, not an administrator cookie.
4. Copy the initial access token and run the public-client walkthrough against the **web** Cloud Run URL printed by the deploy script:

```bash
CONSOLE_URL="https://WEB_CLOUD_RUN_HOST" \
  AGENT_TOKEN="ACCESS_TOKEN_FROM_THE_WIZARD" \
  bash demo/public-weather-tutorial-gcp.sh access
```

The script also prompts privately for the access token if `AGENT_TOKEN` is unset. It checks allowed forecast access, denied requests, and an approval-held elevation call. Approve that request in the signed-in Console, then run:

```bash
CONSOLE_URL="https://WEB_CLOUD_RUN_HOST" \
  AGENT_TOKEN="ACCESS_TOKEN_FROM_THE_WIZARD" \
  bash demo/public-weather-tutorial-gcp.sh approved
```

Finally revoke the delegation in the Console and run the `revoked` phase. Never put the delegation secret or access token in a URL, source control, or shared logs.

The deployment allows the gateway and web services to scale to zero (`min=0`) to avoid baseline instance charges. The first request after an idle period may take longer while Cloud Run starts an instance and the service fetches and verifies its signed licence. If cold starts noticeably affect users, change both deploy flags to `--min=1` and redeploy.

Add `--emotion` to deploy the published private Emotion MCP upstream and wire it to the gateway:

```bash
scripts/deploy-gcp.sh \
  --project-id "$GCP_PROJECT_ID" \
  --version latest \
  --keys-directory /secure/path/to/activation \
  --emotion \
  --apply
```

Without `--emotion`, an allowed MCP request returns the gateway's authorization echo because no upstream is configured. With `--emotion`, the gateway forwards `/mcp-emotion` calls to the private Emotion service using Cloud Run IAM.

Emotion tool discovery and inference use separate processes: `tools/list` can succeed while the model API is still unavailable. If an inference tool reports `Service Unavailable`, inspect the Emotion revision logs for the last health-probe result or a key-staging/startup error:

```bash
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="agw-agent-gateway-dev-emotion" AND textPayload:"emotion:"' \
  --project="$GCP_PROJECT_ID" \
  --freshness=30m \
  --limit=30 \
  --format="value(timestamp,textPayload)"
```

## Tear Down

For a disposable project:

```bash
gcloud projects delete "$GCP_PROJECT_ID"
```

If retaining the project, delete the Cloud Run services, Firestore database, activation bucket, and secrets individually. Keep a secure backup of activation files before deleting them.

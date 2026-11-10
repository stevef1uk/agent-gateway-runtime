# Agent Gateway GCP Deployment

This guide deploys the published encrypted Agent Gateway images into your own Google Cloud project. You do not need the Agent Gateway application source, Go, Terraform, or Docker.

## What you need

- A Google Cloud project with billing enabled.
- `gcloud` installed and authenticated with `gcloud auth login` and `gcloud auth application-default login`.
- This repository contains a deliberately public **evaluation-only** activation pair in `keys/customer_private.pem` and `keys/token.txt`. Anyone who clones this branch can use the public evaluation images.

Do not reuse these evaluation files for production or paid/customer deployments. The deployment script uploads the evaluation customer key and signed licence token to a private, versioned Cloud Storage bucket.

## Deploy

```bash
git clone --branch gcp https://github.com/stevef1uk/agent-gateway-runtime.git
cd agent-gateway-runtime

scripts/deploy-gcp.sh \
  --project-id YOUR_PROJECT_ID \
  --version 2026-11-10-test5 \
  --keys-directory keys \
  --apply
```

The script enables APIs, creates Firestore, service accounts, Secret Manager secrets, the activation bucket, and the two Cloud Run services. It mirrors the public Docker Hub images into your project’s Artifact Registry with Cloud Build, then deploys Cloud Run from that private project registry. Docker is not required on the customer machine.

```text
stevef1uk/agent-gateway-gateway_g:VERSION
stevef1uk/agent-gateway-web_g:VERSION
```

Use the exact release version supplied with your activation material. Do not use `latest`.

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

gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="user:$ACCOUNT" \
  --role="roles/viewer"

gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
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
  --project-id YOUR_PROJECT_ID \
  --version 2026-11-10-test5 \
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
  --project-id YOUR_PROJECT_ID \
  --version 2026-11-10-test5 \
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

The deployment keeps one gateway and one web instance warm so the console health polling does not repeatedly hit cold-start windows. This adds a small baseline Cloud Run cost while the deployment is running.

Add `--emotion` to deploy the published private Emotion MCP upstream and wire it to the gateway:

```bash
scripts/deploy-gcp.sh \
  --project-id YOUR_PROJECT_ID \
  --version 2026-11-10-test5 \
  --keys-directory /secure/path/to/activation \
  --emotion \
  --apply
```

Without `--emotion`, an allowed MCP request returns the gateway's authorization echo because no upstream is configured. With `--emotion`, the gateway forwards `/mcp-emotion` calls to the private Emotion service using Cloud Run IAM.

## Tear Down

For a disposable project:

```bash
gcloud projects delete YOUR_PROJECT_ID
```

If retaining the project, delete the Cloud Run services, Firestore database, activation bucket, and secrets individually. Keep a secure backup of activation files before deleting them.

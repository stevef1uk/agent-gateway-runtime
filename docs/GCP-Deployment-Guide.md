# Agent Gateway GCP Deployment

This guide deploys the published encrypted Agent Gateway images into your own Google Cloud project. You do not need the Agent Gateway application source, Go, Terraform, or Docker.

## What you need

- A Google Cloud project with billing enabled.
- `gcloud` installed and authenticated with `gcloud auth login` and `gcloud auth application-default login`.
- A customer activation directory containing `customer_private.pem` and `token.txt`.

Never upload a vendor private key. The deployment script uploads only the customer private key and signed licence token to a private, versioned Cloud Storage bucket.

## Deploy

```bash
git clone --branch gcp https://github.com/stevef1uk/agent-gateway-runtime.git
cd agent-gateway-runtime

scripts/deploy-gcp.sh \
  --project-id YOUR_PROJECT_ID \
  --version 2026-11-10-test5 \
  --keys-directory /secure/path/to/activation \
  --apply
```

The script enables APIs, creates Firestore, service accounts, Secret Manager secrets, the activation bucket, and the two Cloud Run services. It uses the published Docker Hub images:

```text
stevef1uk/agent-gateway-gateway_g:VERSION
stevef1uk/agent-gateway-web_g:VERSION
```

Use the exact release version supplied with your activation material. Do not use `latest`.

## Google Sign-In

Create a Google OAuth web client in **APIs & Services -> Credentials**. After the script prints the web URL, add this redirect URI to the OAuth client:

```text
https://WEB_CLOUD_RUN_HOST/oidc/callback
```

Then redeploy with the client ID and secret file:

```bash
scripts/deploy-gcp.sh \
  --project-id YOUR_PROJECT_ID \
  --version 2026-11-10-test5 \
  --keys-directory /secure/path/to/activation \
  --oidc-client-id YOUR_CLIENT_ID.apps.googleusercontent.com \
  --oidc-client-secret /secure/path/to/client-secret.txt \
  --apply
```

The client secret is stored in Secret Manager. Google may show an unverified-app warning while the OAuth app is in testing; add your account as a test user.

## Verify

Use the URLs printed by the script:

```bash
curl -i https://WEB_CLOUD_RUN_HOST/healthz
curl -i https://GATEWAY_CLOUD_RUN_HOST/healthz
```

The serverless profile uses Firestore for sessions, delegations, approvals, audit state, and replay protection. Backup/Restore and Kubernetes-only features are intentionally hidden.

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

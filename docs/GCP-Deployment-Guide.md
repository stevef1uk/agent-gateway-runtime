# Agent Gateway GCP Deployment

This guide deploys the published signed-licence Agent Gateway images into your own Google Cloud project. You do not need the Agent Gateway application source, Go, Terraform, or Docker.

For an overview of the deployed services and request flow, see the [GCP architecture](gcp/architecture.md). For indicative operating costs, see the [GCP pricing estimate](gcp/serverless-pricing.md).

## What you need

- A Google Cloud project with billing enabled.
- `gcloud` installed and authenticated with `gcloud auth login` and `gcloud auth application-default login`.
- This repository contains deliberately public **evaluation-only** activation material. `keys/token.txt` is used by the four Agent Gateway service images. By default, the optional Emotion backend uses the model image's bundled evaluation token; it does not require `keys/customer_private.pem`. A vendor-issued customer token can be supplied separately at deployment time.

Do not reuse these evaluation files for production or paid/customer deployments. The deployment script uploads the Agent Gateway signed licence token to a private Cloud Storage bucket. With `--emotion-token-file`, it also uploads the vendor-issued Emotion token to a versioned object and grants access only to the Emotion service account. Keep that token outside Git; the script does not upload the customer private key for Emotion.

For a licensed Emotion deployment, pass the vendor-issued Emotion token with
`--emotion-token-file`. Cloud Run fetches that versioned token at startup; it
does not need to be embedded in the image. The image build does not decrypt
model files; the vendor runtime writes decryption output to ephemeral `/tmp`,
not back into the image. All signed-in users share this licensed Emotion
service and still need their own scoped delegation.

The pinned evaluation image can run without an external customer decryption
key. This is separate from customer-specific model packages, which require
their matching private key and licence token. If an earlier deployment uploaded
`activation/customer_private.pem` or granted the Emotion service account bucket
access, those existing resources are not removed automatically; review them
before removing them if they are no longer needed.

## 1. Prepare the project

```bash
git clone --branch gcp https://github.com/stevef1uk/agent-gateway-runtime.git
cd agent-gateway-runtime

export GCP_PROJECT_ID="YOUR_GCP_PROJECT_ID"
export GCP_DEPLOYMENT_ID="agent-gateway-dev"  # Change if using a different resource prefix.

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

**Admin email configuration:** if you enable Google sign-in with
`--oidc-client-id`, you must also provide `--admin-emails` with one or more
comma-separated, verified Google account addresses allowed to administer the
Console. For example:

```bash
--admin-emails "admin@example.com,operator@example.com"
```

You can set the same value in `GCP_ADMIN_EMAILS` instead. The deployment
script rejects OIDC configuration without an admin allowlist; do not omit this
flag from either the initial OIDC deployment or a later redeployment.

Run a validation-only pass first:

```bash
scripts/deploy-gcp.sh \
  --project-id "$GCP_PROJECT_ID" \
  --deployment-id "$GCP_DEPLOYMENT_ID" \
  --version gcp-28ac097 \
  --keys-directory keys \
  --admin-emails "admin@example.com"
```

Then deploy:

```bash
scripts/deploy-gcp.sh \
  --project-id "$GCP_PROJECT_ID" \
  --deployment-id "$GCP_DEPLOYMENT_ID" \
  --version gcp-28ac097 \
  --keys-directory keys \
  --admin-emails "admin@example.com" \
  --emotion \
  --emotion-token-file keys/local-activation/emotion.token \
  --apply
```

The script enables APIs, creates Firestore, service accounts, Secret Manager secrets, the activation bucket, and the two Cloud Run services. It mirrors the public Docker Hub images into your project’s Artifact Registry with Cloud Build, then deploys Cloud Run from that private project registry. The main services fetch and verify only the signed licence token; the customer key is not mounted into them. Docker is not required on the customer machine.

The configured Wizard demos route weather and geocoding to their respective
Open-Meteo services, and users and simulated refunds to JSONPlaceholder. The
refunds demo uses `/posts` as a simulation: writes are not persisted and no
real refund is issued. Add `--emotion` to deploy the Emotion MCP backend.
The Wizard creates delegations; it does not deploy arbitrary upstreams.

```text
stevef1uk/agent-gateway-gateway_g:VERSION
stevef1uk/agent-gateway-web_g:VERSION
```

The `latest` tag is a moving alias updated whenever a new GCP image release is published. These examples pin `gcp-28ac097`, so deployments use the same tested images each time. To upgrade, choose a specific published release tag and use it consistently; use `latest` only when you intentionally want the newest published images.

## Choosing the policy engine for a delegation

An allowlisted administrator can select the authorization engine for each new
delegation:

1. Sign in to the GCP Console and open the API Wizard to create a delegation.
2. In the delegation settings, choose **Built-in delegation policy** or
   **Rego (OPA) policy** under **Authorization policy engine**. This control is
   shown when the deployment has Rego enabled.
3. Review the selected engine and create the delegation. The Console lists the
   engine on the resulting delegation.

The choice is saved with the delegation and applies to its authorization
decisions. Delegations created without an explicit choice use the built-in
policy; existing delegations retain their saved choice. Child delegations
inherit the parent's engine. This selection does not replace platform security
checks or mandatory GCP approval rules; those apply to both engines.

For step-by-step Console instructions, including editing and restoring Rego
policy versions, see the [GCP Console tutorial](GCP-Console-Tutorial.md).
Policy edits are shared through Firestore and Gateway instances load validated
updates automatically; publishing a new image is not required for policy-only
changes. Only delegations set to Rego use the managed Rego policy.

## Google Sign-In

Google sign-in is a required **second step**. If the first deployment did not include `--oidc-client-id` and `--oidc-client-secret`, the console deliberately displays:

```json
{"error":"oidc is not enabled; unset OIDC_ISSUER_URL to use dev mode"}
```

That means the infrastructure is deployed, but browser sign-in has not been configured yet.

When enabling Google sign-in, provide `--admin-emails` with the comma-separated,
verified Google account email addresses that may administer this deployment.
The private Console refuses to start with OIDC enabled but no configured admin
allowlist; non-listed accounts cannot sign in to the private Console.

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

Then redeploy with the client ID and secret file. The examples below include
`--emotion` to retain the optional Emotion upstream; omit it if you do not
want to configure Emotion.

```bash
scripts/deploy-gcp.sh \
  --project-id "$GCP_PROJECT_ID" \
  --deployment-id "$GCP_DEPLOYMENT_ID" \
  --version gcp-28ac097 \
  --keys-directory keys \
  --emotion \
  --oidc-client-id YOUR_CLIENT_ID.apps.googleusercontent.com \
  --oidc-client-secret /secure/path/to/client-secret.txt \
  --admin-emails "admin@example.com" \
  --apply
```

Alternatively, enter the secret interactively without putting it in shell history:

```bash
read -r -s -p "Google OAuth client secret: " GCP_OIDC_CLIENT_SECRET
echo
export GCP_OIDC_CLIENT_SECRET

scripts/deploy-gcp.sh \
  --project-id "$GCP_PROJECT_ID" \
  --deployment-id "$GCP_DEPLOYMENT_ID" \
  --version gcp-28ac097 \
  --keys-directory keys \
  --emotion \
  --oidc-client-id YOUR_CLIENT_ID.apps.googleusercontent.com \
  --admin-emails "admin@example.com" \
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

1. Sign in to the Console and open **API Wizard**. Create a delegation scoped to `/v1/forecast` and `/v1/elevation` with the `read` action. To exercise approval, add an approval rule for `read` on `/v1/elevation`. Complete the Wizard and retain the delegation ID and one-time agent secret securely.
2. The Wizard's **Token** tab provides a GCP refresh command for `/api/agent/token`. It uses the delegation ID and agent secret (not an administrator cookie) to mint a short-lived access token. Keep the secret private; do not put it in source control or shared logs.
3. From the runtime repository root, run the live GCP walkthrough against the **web Console** Cloud Run URL printed by the deploy script:

```bash
CONSOLE_URL="https://WEB_CLOUD_RUN_HOST" bash demo/public-weather-tutorial-gcp.sh access
```

The script prompts privately for an access token if `AGENT_TOKEN` is unset. Paste the Wizard's initial token, or use the Token tab's refresh command if it has expired. The `access` phase checks allowed forecast access, denied requests, and an approval-held elevation call. It also verifies that a caller cannot bypass method-based policy by supplying an `X-Agent-Action` header. The GCP deploy script configures the Gateway to ignore caller-supplied action/resource overrides; rerun it with `--apply` to update an existing deployment.

Approve the pending elevation request in the signed-in Console, then run the next phase and enter the same still-valid token when prompted:

```bash
CONSOLE_URL="https://WEB_CLOUD_RUN_HOST" bash demo/public-weather-tutorial-gcp.sh approved
```

The `approved` phase checks that the elevation approval grants one request and that a subsequent request is held again. Finally, revoke the delegation in the Console and run the `revoked` phase before the token expires; it verifies the token is rejected:

```bash
CONSOLE_URL="https://WEB_CLOUD_RUN_HOST" bash demo/public-weather-tutorial-gcp.sh revoked
```

The script makes requests to the public Console URL, which proxies to the private Gateway. Never put the delegation secret or access token in a URL, source control, or shared logs.

The deployment allows the gateway and web services to scale to zero (`min=0`) to avoid baseline instance charges. The first request after an idle period may take longer while Cloud Run starts an instance and the service fetches and verifies its signed licence. If cold starts noticeably affect users, change both deploy flags to `--min=1` and redeploy.

Add `--emotion` to deploy the published private Emotion MCP upstream and wire it to the gateway:

```bash
scripts/deploy-gcp.sh \
  --project-id "$GCP_PROJECT_ID" \
  --deployment-id "$GCP_DEPLOYMENT_ID" \
  --version gcp-28ac097 \
  --keys-directory keys \
  --emotion \
  --oidc-client-id YOUR_CLIENT_ID.apps.googleusercontent.com \
  --oidc-client-secret /secure/path/to/client-secret.txt \
  --admin-emails "admin@example.com" \
  --apply
```

For a customer/vendor-issued Emotion licence, save the token outside source control, for example as `keys/local-activation/emotion.token` (the `keys/` directory is Git-ignored), then add:

```bash
  --emotion-token-file keys/local-activation/emotion.token
```

The deployment pins the uploaded object generation in the Emotion Cloud Run revision and grants that service account read access only to `activation/emotion.token`. Omitting the flag retains the image's bundled evaluation token; a subsequent deployment without the flag preserves any already-configured token environment values.

Include the OIDC options when Google sign-in is configured; otherwise, omit them.
Without `--emotion`, an allowed MCP request returns the gateway's authorization echo because no upstream is configured. With `--emotion`, the gateway forwards `/mcp-emotion` calls to the private Emotion service using Cloud Run IAM.

Emotion tool discovery and inference use separate processes: `tools/list` can succeed while the model API is still unavailable. The Console tester checks `/mcp-emotion/healthz` and waits while the inference backends report `warming`; if the readiness endpoint returns 404, it warns and proceeds with the actual tool call instead of blocking it. The delegation must allow `list` on `/mcp-emotion*` for this check. With `--emotion`, the Gateway also requires a human approval for `emotion_detection_detailed`, even if an individual delegation omitted that approval rule; ordinary `emotion_detection` remains governed by its delegation. The GCP Emotion image build verifies that the llama.cpp runtime can load its shared libraries. If an inference tool reports `Service Unavailable`, inspect the Emotion revision logs for the last health-probe result:

```bash
gcloud logging read \
  "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"agw-${GCP_DEPLOYMENT_ID}-emotion\" AND textPayload:\"emotion:\"" \
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

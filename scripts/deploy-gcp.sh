#!/usr/bin/env bash
# Deploy the published Agent Gateway GCP images into a customer's project.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/deploy-gcp.sh --project-id PROJECT --version VERSION [options]

Required:
  --project-id PROJECT       GCP project ID with billing enabled
  --version VERSION          Published Docker Hub release tag

Options:
  --region REGION            Cloud Run region (default: europe-west9)
  --deployment-id ID         Resource name prefix (default: agent-gateway-dev)
  --keys-directory DIR       Directory containing customer_private.pem and token.txt
                             (default: ./keys)
  --emotion                  Deploy and wire the published Emotion MCP upstream
  --oidc-client-id ID        Google OAuth client ID
  --oidc-client-secret FILE  File containing the Google OAuth client secret
  --apply                    Create/update resources; otherwise only validate inputs
  --help                     Show this help
EOF
  exit 2
}

project_id=""
version=""
region="europe-west9"
deployment_id="agent-gateway-dev"
keys_directory="keys"
oidc_client_id="${GCP_OIDC_CLIENT_ID:-}"
oidc_client_secret_file=""
apply=0
emotion=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id) [[ $# -ge 2 ]] || usage; project_id=$2; shift 2 ;;
    --version) [[ $# -ge 2 ]] || usage; version=$2; shift 2 ;;
    --region) [[ $# -ge 2 ]] || usage; region=$2; shift 2 ;;
    --deployment-id) [[ $# -ge 2 ]] || usage; deployment_id=$2; shift 2 ;;
    --keys-directory) [[ $# -ge 2 ]] || usage; keys_directory=$2; shift 2 ;;
    --oidc-client-id) [[ $# -ge 2 ]] || usage; oidc_client_id=$2; shift 2 ;;
    --oidc-client-secret) [[ $# -ge 2 ]] || usage; oidc_client_secret_file=$2; shift 2 ;;
    --emotion) emotion=1; shift ;;
    --apply) apply=1; shift ;;
    --help|-h) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -n "$project_id" && -n "$version" ]] || usage
[[ "$version" != latest ]] || { echo 'Use a versioned release tag, never latest.' >&2; exit 2; }

for command in gcloud openssl; do
  command -v "$command" >/dev/null 2>&1 || { echo "Required command not found: $command" >&2; exit 1; }
done

customer_key="$keys_directory/customer_private.pem"
licence_token="$keys_directory/token.txt"
[[ -s "$customer_key" ]] || { echo "Missing $customer_key" >&2; exit 1; }
[[ -s "$licence_token" ]] || { echo "Missing $licence_token" >&2; exit 1; }

if [[ -n "$oidc_client_id" && -z "$oidc_client_secret_file" ]]; then
  if [[ -n "${GCP_OIDC_CLIENT_SECRET:-}" ]]; then
    oidc_client_secret_file="$(mktemp)"
    chmod 600 "$oidc_client_secret_file"
    printf '%s' "$GCP_OIDC_CLIENT_SECRET" > "$oidc_client_secret_file"
    trap 'rm -f "$oidc_client_secret_file"' EXIT
  else
    echo '--oidc-client-secret FILE or GCP_OIDC_CLIENT_SECRET is required when --oidc-client-id is supplied.' >&2
    exit 2
  fi
fi
if [[ -n "$oidc_client_secret_file" ]]; then
  [[ -s "$oidc_client_secret_file" ]] || { echo "Missing OIDC secret file: $oidc_client_secret_file" >&2; exit 1; }
fi

gcloud config set project "$project_id" >/dev/null
gcloud services enable \
  run.googleapis.com firestore.googleapis.com secretmanager.googleapis.com \
  storage.googleapis.com aiplatform.googleapis.com iam.googleapis.com \
  iamcredentials.googleapis.com identitytoolkit.googleapis.com \
  artifactregistry.googleapis.com cloudbuild.googleapis.com

bucket="${project_id}-agw-activation"
gateway_service="agw-${deployment_id}-gateway"
web_service="agw-${deployment_id}-web"
gateway_sa="agw-${deployment_id}-gateway@${project_id}.iam.gserviceaccount.com"
web_sa="agw-${deployment_id}-web@${project_id}.iam.gserviceaccount.com"
jwt_secret="agw-${deployment_id}-jwt-secret"
admin_secret="agw-${deployment_id}-admin-token"
oidc_secret="agw-${deployment_id}-oidc-client-secret"
registry="stevef1uk"
artifact_repo="${region}-docker.pkg.dev/${project_id}/agent-gateway"

ensure_service_account() {
  local account=$1
  local email="$account@$project_id.iam.gserviceaccount.com"
  if ! gcloud iam service-accounts describe "$email" --project="$project_id" >/dev/null 2>&1; then
    gcloud iam service-accounts create "$account" --project="$project_id"
  fi
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    gcloud iam service-accounts describe "$email" --project="$project_id" >/dev/null 2>&1 && return
    sleep 2
  done
  echo "Service account did not become readable: $email" >&2
  exit 1
}

ensure_secret() {
  local name=$1
  gcloud secrets describe "$name" --project="$project_id" >/dev/null 2>&1 || \
    gcloud secrets create "$name" --replication-policy="user-managed" --locations="$region" --project="$project_id"
}

if [[ "$apply" -eq 0 ]]; then
  echo "Validated activation files and project inputs. Re-run with --apply to deploy."
  exit 0
fi

gcloud storage buckets describe "gs://$bucket" --project="$project_id" >/dev/null 2>&1 || \
  gcloud storage buckets create "gs://$bucket" --location="$region" --uniform-bucket-level-access --project="$project_id"
gcloud storage cp "$customer_key" "gs://$bucket/activation/customer_private.pem"
gcloud storage cp "$licence_token" "gs://$bucket/activation/licence.token"

ensure_service_account "agw-${deployment_id}-gateway"
ensure_service_account "agw-${deployment_id}-web"
ensure_secret "$jwt_secret"
ensure_secret "$admin_secret"

if gcloud secrets versions list "$jwt_secret" --project="$project_id" --format='value(name)' | grep -q .; then :; else printf '%s' "$(openssl rand -base64 32)" | gcloud secrets versions add "$jwt_secret" --data-file=- --project="$project_id"; fi
if gcloud secrets versions list "$admin_secret" --project="$project_id" --format='value(name)' | grep -q .; then :; else printf '%s' "$(openssl rand -base64 32)" | gcloud secrets versions add "$admin_secret" --data-file=- --project="$project_id"; fi

if [[ -n "$oidc_client_id" ]]; then
  ensure_secret "$oidc_secret"
  gcloud secrets versions add "$oidc_secret" --data-file="$oidc_client_secret_file" --project="$project_id"
  gcloud secrets add-iam-policy-binding "$oidc_secret" --project="$project_id" \
    --member="serviceAccount:$web_sa" --role=roles/secretmanager.secretAccessor --quiet >/dev/null
fi

for service_account in "$gateway_sa" "$web_sa"; do
  gcloud projects add-iam-policy-binding "$project_id" --member="serviceAccount:$service_account" --role=roles/datastore.user --quiet >/dev/null
  gcloud projects add-iam-policy-binding "$project_id" --member="serviceAccount:$service_account" --role=roles/aiplatform.user --quiet >/dev/null
  gcloud secrets add-iam-policy-binding "$jwt_secret" --project="$project_id" --member="serviceAccount:$service_account" --role=roles/secretmanager.secretAccessor --quiet >/dev/null
  gcloud secrets add-iam-policy-binding "$admin_secret" --project="$project_id" --member="serviceAccount:$service_account" --role=roles/secretmanager.secretAccessor --quiet >/dev/null
  gcloud storage buckets add-iam-policy-binding "gs://$bucket" --member="serviceAccount:$service_account" --role=roles/storage.objectViewer --quiet >/dev/null
done

image_base="$artifact_repo"
activation_env="LICENCE_GCS_BUCKET=$bucket,CUSTOMER_KEY_GCS_OBJECT=activation/customer_private.pem,CUSTOMER_KEY_GCS_GENERATION=$(gcloud storage objects describe "gs://$bucket/activation/customer_private.pem" --format='value(generation)'),LICENCE_GCS_OBJECT=activation/licence.token,LICENCE_GCS_GENERATION=$(gcloud storage objects describe "gs://$bucket/activation/licence.token" --format='value(generation)')"

gcloud firestore databases describe --database='(default)' --project="$project_id" >/dev/null 2>&1 || \
  gcloud firestore databases create --database='(default)' --location="$region" --type=firestore-native --project="$project_id"

gcloud artifacts repositories describe agent-gateway --location="$region" --project="$project_id" >/dev/null 2>&1 || \
  gcloud artifacts repositories create agent-gateway --repository-format=docker --location="$region" --description="Agent Gateway customer image mirror" --project="$project_id"

mirror_image() {
  local name=$1
  local source="docker.io/$registry/agent-gateway-${name}_g:$version"
  local destination="$artifact_repo/agent-gateway-${name}_g:$version"
  local context
  if gcloud artifacts docker images describe "$destination" --project="$project_id" >/dev/null 2>&1; then
    echo "Using existing mirrored image: $destination"
    return
  fi
  context="$(mktemp -d)"
  printf 'FROM --platform=linux/amd64 %s\n' "$source" > "$context/Dockerfile"
  echo "Mirroring $source to $destination with Cloud Build..."
  gcloud builds submit "$context" --tag="$destination" --project="$project_id" --quiet
  rm -rf "$context"
}

mirror_image gateway
mirror_image web
if [[ "$emotion" -eq 1 ]]; then
  mirror_image emotion
fi

# The Firestore domain store queries by partition key and sort key. Existing
# indexes are harmless; a duplicate create is ignored on repeat deployments.
gcloud firestore indexes composite create --collection-group=agw_domains \
  --field-config=field-path=pk,order=ascending \
  --field-config=field-path=sk,order=ascending \
  --database='(default)' --project="$project_id" >/dev/null 2>&1 || true
gcloud firestore indexes composite create --collection-group=agw_domains \
  --field-config=field-path=pk,order=ascending \
  --field-config=field-path=sk,order=descending \
  --database='(default)' --project="$project_id" >/dev/null 2>&1 || true

gcloud run deploy "$gateway_service" \
  --image="$image_base/agent-gateway-gateway_g:$version" --region="$region" --project="$project_id" \
  --service-account="$gateway_sa" --allow-unauthenticated --port=8080 --cpu=1 --memory=512Mi --timeout=60s --concurrency=80 --max-instances=10 \
  --set-env-vars="SERVICE_NAME=gateway,CONSOLIDATED_CONTROL_PLANE=1,PERSISTENCE=firestore,FIRESTORE_PROJECT_ID=$project_id,FIRESTORE_DATABASE_ID=(default),FIRESTORE_NAMESPACE=$deployment_id,FIRESTORE_SECURITY_NAMESPACE=${deployment_id}-sec,INTERNAL_GCP_IAM=1,GCP_INTERNAL_AUDIENCE=https://bootstrap.invalid,GCP_INTERNAL_CALLER_EMAILS=$web_sa,$activation_env" \
  --set-secrets="JWT_SECRET=$jwt_secret:latest,GATEWAY_ADMIN_TOKEN=$admin_secret:latest"

gateway_url="$(gcloud run services describe "$gateway_service" --region="$region" --project="$project_id" --format='value(status.url)')"
gcloud run services update "$gateway_service" --region="$region" --project="$project_id" --update-env-vars="GCP_INTERNAL_AUDIENCE=$gateway_url"

if [[ "$emotion" -eq 1 ]]; then
  emotion_service="agw-${deployment_id}-emotion"
  emotion_sa="agw-${deployment_id}-emotion@${project_id}.iam.gserviceaccount.com"
  ensure_service_account "agw-${deployment_id}-emotion"
  gcloud storage buckets add-iam-policy-binding "gs://$bucket" --member="serviceAccount:$emotion_sa" --role=roles/storage.objectViewer --quiet >/dev/null
  gcloud run deploy "$emotion_service" \
    --image="$image_base/agent-gateway-emotion_g:$version" --region="$region" --project="$project_id" \
    --service-account="$emotion_sa" --no-allow-unauthenticated --port=8085 --cpu=2 --memory=4Gi --timeout=180s --concurrency=10 --max-instances=2 \
    --set-env-vars="EMOTION_BRIDGE_PORT=8085,LICENCE_GCS_BUCKET=$bucket,CUSTOMER_KEY_GCS_OBJECT=activation/customer_private.pem,CUSTOMER_KEY_GCS_GENERATION=$(gcloud storage objects describe "gs://$bucket/activation/customer_private.pem" --format='value(generation)')"
  gcloud run services add-iam-policy-binding "$emotion_service" --region="$region" --project="$project_id" \
    --member="serviceAccount:$gateway_sa" --role=roles/run.invoker --quiet >/dev/null
  emotion_url="$(gcloud run services describe "$emotion_service" --region="$region" --project="$project_id" --format='value(status.url)')"
  gcloud run services update "$gateway_service" --region="$region" --project="$project_id" \
    --update-env-vars="UPSTREAM_URL=$emotion_url,UPSTREAM_GCP_IAM=1"
fi

web_env="SERVICE_NAME=web,PERSISTENCE=firestore,FIRESTORE_PROJECT_ID=$project_id,FIRESTORE_DATABASE_ID=(default),FIRESTORE_NAMESPACE=$deployment_id,FIRESTORE_SECURITY_NAMESPACE=${deployment_id}-sec,GATEWAY_URL=$gateway_url,GATEWAY_MCP_URL=$gateway_url,AUTHZ_URL=$gateway_url,TOKENSVC_URL=$gateway_url,INTERNAL_GCP_IAM=1,AUTHZ_GCP_IAM=1,SERVERLESS_PROFILE=1,WEB_IDP_RELAY=0,$activation_env"
secret_args="GATEWAY_ADMIN_TOKEN=$admin_secret:latest"
if [[ -n "$oidc_client_id" ]]; then
  web_env+=" ,OIDC_ISSUER_URL=https://accounts.google.com,OIDC_CLIENT_ID=$oidc_client_id"
  secret_args+=",OIDC_CLIENT_SECRET=$oidc_secret:latest"
fi

gcloud run deploy "$web_service" \
  --image="$image_base/agent-gateway-web_g:$version" --region="$region" --project="$project_id" \
  --service-account="$web_sa" --allow-unauthenticated --port=8080 --cpu=1 --memory=512Mi --timeout=60s --concurrency=80 --max-instances=10 \
  --set-env-vars="${web_env// ,/,}" --set-secrets="$secret_args"

echo "Gateway URL: $gateway_url"
web_url="$(gcloud run services describe "$web_service" --region="$region" --project="$project_id" --format='value(status.url)')"
echo "Web URL: $web_url"
if [[ -z "$oidc_client_id" ]]; then
  echo "OIDC is not enabled yet. Create a Google OAuth client with this redirect URI, then rerun with --oidc-client-id and --oidc-client-secret:"
  echo "  $web_url/oidc/callback"
fi

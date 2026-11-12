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
  --version VERSION          Published Docker Hub release tag, or latest (moving alias)

Options:
  --region REGION            Cloud Run region (default: europe-west9)
  --deployment-id ID         Resource name prefix (default: agent-gateway-dev)
  --keys-directory DIR       Directory containing token.txt (default: ./keys)
  --emotion                  Deploy and wire the published Emotion MCP upstream
  --emotion-token-file FILE  Upload a vendor-issued Emotion token from outside Git
  --oidc-client-id ID        Google OAuth client ID
  --oidc-client-secret FILE  File containing the Google OAuth client secret
  --admin-emails EMAILS      Comma-separated verified Google admin emails (required with OIDC)
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
admin_emails="${GCP_ADMIN_EMAILS:-}"
apply=0
emotion=0
emotion_token_file="${EMOTION_TOKEN_FILE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-id) [[ $# -ge 2 ]] || usage; project_id=$2; shift 2 ;;
    --version) [[ $# -ge 2 ]] || usage; version=$2; shift 2 ;;
    --region) [[ $# -ge 2 ]] || usage; region=$2; shift 2 ;;
    --deployment-id) [[ $# -ge 2 ]] || usage; deployment_id=$2; shift 2 ;;
    --keys-directory) [[ $# -ge 2 ]] || usage; keys_directory=$2; shift 2 ;;
    --emotion-token-file) [[ $# -ge 2 ]] || usage; emotion_token_file=$2; shift 2 ;;
    --oidc-client-id) [[ $# -ge 2 ]] || usage; oidc_client_id=$2; shift 2 ;;
    --oidc-client-secret) [[ $# -ge 2 ]] || usage; oidc_client_secret_file=$2; shift 2 ;;
    --admin-emails) [[ $# -ge 2 ]] || usage; admin_emails=$2; shift 2 ;;
    --emotion) emotion=1; shift ;;
    --apply) apply=1; shift ;;
    --help|-h) usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

[[ -n "$project_id" && -n "$version" ]] || usage
[[ "$version" == latest || "$version" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || {
  echo 'Version must be a valid Docker tag.' >&2
  exit 2
}
if [[ -n "$oidc_client_id" && -z "$admin_emails" ]]; then
  echo '--admin-emails or GCP_ADMIN_EMAILS is required when Google sign-in is enabled.' >&2
  exit 2
fi

for command in gcloud openssl python3; do
  command -v "$command" >/dev/null 2>&1 || { echo "Required command not found: $command" >&2; exit 1; }
done

licence_token="$keys_directory/token.txt"
[[ -s "$licence_token" ]] || { echo "Missing $licence_token" >&2; exit 1; }
if [[ -n "$emotion_token_file" ]]; then
  [[ "$emotion" -eq 1 ]] || { echo '--emotion-token-file requires --emotion.' >&2; exit 2; }
  [[ -s "$emotion_token_file" ]] || { echo "Missing Emotion licence token: $emotion_token_file" >&2; exit 1; }
  [[ "$(wc -c < "$emotion_token_file")" -le 65536 ]] || {
    echo 'Emotion licence token must not exceed 64 KiB.' >&2
    exit 1
  }
fi

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
  normalized_secret_file="$(mktemp)"
  chmod 600 "$normalized_secret_file"
  tr -d '\r\n' < "$oidc_client_secret_file" > "$normalized_secret_file"
  oidc_client_secret_file="$normalized_secret_file"
  trap 'rm -f "$normalized_secret_file"' EXIT
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
if [[ -n "$emotion_token_file" ]]; then
  gcloud storage buckets update "gs://$bucket" --versioning >/dev/null
fi
file_md5_b64() {
  openssl dgst -md5 -binary "$1" | base64 | tr -d '\n'
}

upload_if_changed() {
  local file=$1
  local object=$2
  local remote_md5
  local local_md5
  remote_md5="$(gcloud storage objects describe "gs://$bucket/$object" --format='value(md5Hash)' 2>/dev/null || true)"
  local_md5="$(file_md5_b64 "$file")"
  if [[ -n "$remote_md5" && "$remote_md5" == "$local_md5" ]]; then
    echo "Keeping existing activation object: gs://$bucket/$object"
    return
  fi
  gcloud storage cp "$file" "gs://$bucket/$object"
}

upload_if_changed "$licence_token" "activation/licence.token"
if [[ -n "$emotion_token_file" ]]; then
  upload_if_changed "$emotion_token_file" "activation/emotion.token"
fi

ensure_service_account "agw-${deployment_id}-gateway"
ensure_service_account "agw-${deployment_id}-web"
if [[ "$emotion" -eq 1 ]]; then
  ensure_service_account "agw-${deployment_id}-emotion"
fi
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
  policy="$(gcloud storage buckets get-iam-policy "gs://$bucket" --format=json)"
  if printf '%s' "$policy" | python3 -c '
import json,sys
policy=json.load(sys.stdin)
member=sys.argv[1]
raise SystemExit(0 if any(
    binding.get("role") == "roles/storage.objectViewer"
    and not binding.get("condition")
    and member in binding.get("members", [])
    for binding in policy.get("bindings", [])
) else 1)
' "serviceAccount:$service_account"; then
    gcloud storage buckets remove-iam-policy-binding "gs://$bucket" \
      --member="serviceAccount:$service_account" --role=roles/storage.objectViewer --quiet >/dev/null
  fi
  gcloud storage buckets add-iam-policy-binding "gs://$bucket" \
    --member="serviceAccount:$service_account" --role=roles/storage.objectViewer \
    --condition="expression=resource.name == 'projects/_/buckets/$bucket/objects/activation/licence.token',title=Read licence only,description=Limit service activation access to the signed licence token" \
    --quiet >/dev/null
done
if [[ -n "$emotion_token_file" ]]; then
  emotion_sa="agw-${deployment_id}-emotion@${project_id}.iam.gserviceaccount.com"
  policy="$(gcloud storage buckets get-iam-policy "gs://$bucket" --format=json)"
  if printf '%s' "$policy" | python3 -c '
import json,sys
policy=json.load(sys.stdin)
member=sys.argv[1]
raise SystemExit(0 if any(
    binding.get("role") == "roles/storage.objectViewer"
    and not binding.get("condition")
    and member in binding.get("members", [])
    for binding in policy.get("bindings", [])
) else 1)
' "serviceAccount:$emotion_sa"; then
    gcloud storage buckets remove-iam-policy-binding "gs://$bucket" \
      --member="serviceAccount:$emotion_sa" --role=roles/storage.objectViewer --quiet >/dev/null
  fi
  gcloud storage buckets add-iam-policy-binding "gs://$bucket" \
    --member="serviceAccount:$emotion_sa" --role=roles/storage.objectViewer \
    --condition="expression=resource.name == 'projects/_/buckets/$bucket/objects/activation/emotion.token',title=Read Emotion licence only,description=Limit Emotion service access to its signed licence token" \
    --quiet >/dev/null
fi

# Allow the bucket's conditional IAM grants to propagate before creating new
# Cloud Run revisions; the launcher retries transient reads but must start validly.
echo "Waiting for Cloud Storage IAM propagation before starting Cloud Run..."
sleep 120

image_base="$artifact_repo"
activation_env="LICENCE_GCS_BUCKET=$bucket,LICENCE_GCS_OBJECT=activation/licence.token,LICENCE_GCS_GENERATION=$(gcloud storage objects describe "gs://$bucket/activation/licence.token" --format='value(generation)')"
emotion_token_generation=""
if [[ -n "$emotion_token_file" ]]; then
  emotion_token_generation="$(gcloud storage objects describe "gs://$bucket/activation/emotion.token" --format='value(generation)')"
  [[ -n "$emotion_token_generation" && "$emotion_token_generation" != "null" ]] || {
    echo 'Could not pin a generation for the uploaded Emotion licence token.' >&2
    exit 1
  }
fi

gcloud firestore databases describe --database='(default)' --project="$project_id" >/dev/null 2>&1 || \
  gcloud firestore databases create --database='(default)' --location="$region" --type=firestore-native --project="$project_id"

gcloud artifacts repositories describe agent-gateway --location="$region" --project="$project_id" >/dev/null 2>&1 || \
  gcloud artifacts repositories create agent-gateway --repository-format=docker --location="$region" --description="Agent Gateway customer image mirror" --project="$project_id"

mirror_image() {
  local name=$1
  local source="docker.io/$registry/agent-gateway-${name}_g:$version"
  local destination="$artifact_repo/agent-gateway-${name}_g:$version"
  local context
  if [[ "$version" != latest ]] && gcloud artifacts docker images describe "$destination" --project="$project_id" >/dev/null 2>&1; then
    echo "Using existing mirrored image: $destination"
    return
  fi
  context="$(mktemp -d)"
  printf 'FROM --platform=linux/amd64 %s\n' "$source" > "$context/Dockerfile"
  cat > "$context/cloudbuild.yaml" <<EOF
steps:
  - name: gcr.io/cloud-builders/docker
    args: ['build', '--pull', '--no-cache', '-t', '$destination', '.']
  - name: gcr.io/cloud-builders/docker
    args: ['push', '$destination']
images: ['$destination']
EOF
  echo "Mirroring $source to $destination with Cloud Build..."
  # A fresh pull and disabled Docker layer cache are required for moving tags.
  gcloud builds submit "$context" --config="$context/cloudbuild.yaml" --project="$project_id" --quiet
  rm -rf "$context"
}

mirror_image gateway
mirror_image web
if [[ "$emotion" -eq 1 ]]; then
  mirror_image emotion
fi

echo "Creating/checking Firestore composite indexes; Google may take several minutes..."
# The Firestore domain store queries by partition key and sort key. Existing
# indexes are harmless; a duplicate create is ignored on repeat deployments.
gcloud firestore indexes composite create --collection-group=agw_domains \
  --field-config=field-path=pk,order=ascending \
  --field-config=field-path=sk,order=ascending \
  --database='(default)' --project="$project_id" >/dev/null 2>&1 || true
echo "Ascending Firestore index request complete; waiting for Google index operations as needed..."
gcloud firestore indexes composite create --collection-group=agw_domains \
  --field-config=field-path=pk,order=ascending \
  --field-config=field-path=sk,order=descending \
  --database='(default)' --project="$project_id" >/dev/null 2>&1 || true
echo "Descending Firestore index request complete. Deploying Cloud Run services..."

gateway_env="SERVICE_NAME=gateway,CONSOLIDATED_CONTROL_PLANE=1,PERSISTENCE=firestore,FIRESTORE_PROJECT_ID=$project_id,FIRESTORE_DATABASE_ID=(default),FIRESTORE_NAMESPACE=$deployment_id,FIRESTORE_SECURITY_NAMESPACE=${deployment_id}-sec,INTERNAL_GCP_IAM=1,GCP_INTERNAL_AUDIENCE=https://bootstrap.invalid,GCP_INTERNAL_CALLER_EMAILS=$web_sa,GATEWAY_IGNORE_AGENT_OVERRIDES=1,GCP_REGO_ENABLED=1,$activation_env"
gateway_env+=",UPSTREAM_URL=https://api.open-meteo.com,UPSTREAM_GEOCODING_URL=https://geocoding-api.open-meteo.com,UPSTREAM_DEMO_API_URL=https://jsonplaceholder.typicode.com,UPSTREAM_STRIP_CREDENTIALS=1"
if [[ "$emotion" -eq 1 ]]; then
  gateway_env+=",GCP_EMOTION_DETAILED_APPROVAL=1"
fi
if [[ -n "$oidc_client_id" ]]; then
  gateway_env+=",OIDC_ISSUER_URL=https://accounts.google.com,OIDC_CLIENT_ID=$oidc_client_id"
fi

gcloud beta run deploy "$gateway_service" \
  --image="$image_base/agent-gateway-gateway_g:$version" --region="$region" --project="$project_id" \
    --service-account="$gateway_sa" --no-allow-unauthenticated --port=8080 --cpu=1 --memory=512Mi --timeout=120s --concurrency=80 --min=0 --max-instances=10 \
    --startup-probe="timeoutSeconds=5,periodSeconds=5,failureThreshold=24,httpGet.path=/healthz/,httpGet.port=8080" \
    --readiness-probe="timeoutSeconds=5,periodSeconds=5,failureThreshold=3,successThreshold=1,httpGet.path=/healthz/,httpGet.port=8080" \
  --set-env-vars="$gateway_env" \
  --set-secrets="JWT_SECRET=$jwt_secret:latest,GATEWAY_ADMIN_TOKEN=$admin_secret:latest"

gcloud run services add-iam-policy-binding "$gateway_service" --region="$region" --project="$project_id" \
  --member="serviceAccount:$web_sa" --role=roles/run.invoker --quiet >/dev/null

gateway_url="$(gcloud run services describe "$gateway_service" --region="$region" --project="$project_id" --format='value(status.url)')"
[[ -n "$gateway_url" ]] || { echo "Could not discover the deployed gateway URL" >&2; exit 1; }
gcloud run services update "$gateway_service" --region="$region" --project="$project_id" --update-env-vars="GCP_INTERNAL_AUDIENCE=$gateway_url"

if [[ "$emotion" -eq 1 ]]; then
  emotion_service="agw-${deployment_id}-emotion"
  emotion_sa="agw-${deployment_id}-emotion@${project_id}.iam.gserviceaccount.com"
  emotion_env="EMOTION_BRIDGE_PORT=8085"
  emotion_env_args=(--update-env-vars="$emotion_env")
  if [[ -n "$emotion_token_file" ]]; then
    emotion_env+=",EMOTION_LICENCE_GCS_BUCKET=$bucket,EMOTION_LICENCE_GCS_OBJECT=activation/emotion.token,EMOTION_LICENCE_GCS_GENERATION=$emotion_token_generation"
    emotion_env_args=(--set-env-vars="$emotion_env")
  fi
  gcloud run deploy "$emotion_service" \
    --image="$image_base/agent-gateway-emotion_g:$version" --region="$region" --project="$project_id" \
    --service-account="$emotion_sa" --no-allow-unauthenticated --port=8085 --cpu=2 --memory=4Gi --timeout=180s --concurrency=10 --max-instances=2 \
    "${emotion_env_args[@]}"
  gcloud run services add-iam-policy-binding "$emotion_service" --region="$region" --project="$project_id" \
    --member="serviceAccount:$gateway_sa" --role=roles/run.invoker --quiet >/dev/null
  emotion_url="$(gcloud run services describe "$emotion_service" --region="$region" --project="$project_id" --format='value(status.url)')"
  gcloud run services update "$gateway_service" --region="$region" --project="$project_id" \
    --update-env-vars="UPSTREAM_MCP_URL=$emotion_url,UPSTREAM_MCP_GCP_IAM=1"
fi

web_env="SERVICE_NAME=web,PERSISTENCE=firestore,FIRESTORE_PROJECT_ID=$project_id,FIRESTORE_DATABASE_ID=(default),FIRESTORE_NAMESPACE=$deployment_id,FIRESTORE_SECURITY_NAMESPACE=${deployment_id}-sec,GATEWAY_URL=$gateway_url,GATEWAY_MCP_URL=$gateway_url,AUTHZ_URL=$gateway_url,TOKENSVC_URL=$gateway_url,INTERNAL_GCP_IAM=1,AUTHZ_GCP_IAM=1,SERVERLESS_PROFILE=1,GCP_SERVERLESS_PROFILE=1,GCP_REGO_ENABLED=1,WEATHER_DEMO_ENABLED=true,GCP_DEMO_ROUTES_ENABLED=1,GCP_EMOTION_DEMO_ENABLED=$emotion,WEB_IDP_RELAY=0,$activation_env"
web_env="${web_env// ,/,}"
web_env="${web_env//,/|}"
web_env+="|WEB_ADMIN_EMAILS=$admin_emails"
secret_args="GATEWAY_ADMIN_TOKEN=$admin_secret:latest"
if [[ -n "$oidc_client_id" ]]; then
  web_env+="|OIDC_ISSUER_URL=https://accounts.google.com|OIDC_CLIENT_ID=$oidc_client_id"
  secret_args+=",OIDC_CLIENT_SECRET=$oidc_secret:latest"
fi

gcloud beta run deploy "$web_service" \
  --image="$image_base/agent-gateway-web_g:$version" --region="$region" --project="$project_id" \
    --service-account="$web_sa" --allow-unauthenticated --port=8080 --cpu=1 --memory=512Mi --timeout=120s --concurrency=80 --min=0 --max-instances=1 \
    --startup-probe="timeoutSeconds=5,periodSeconds=5,failureThreshold=24,httpGet.path=/healthz/,httpGet.port=8080" \
    --readiness-probe="timeoutSeconds=5,periodSeconds=5,failureThreshold=3,successThreshold=1,httpGet.path=/healthz/,httpGet.port=8080" \
  --set-env-vars="^|^$web_env" --set-secrets="$secret_args"

echo "Gateway URL: $gateway_url"
web_url="$(gcloud run services describe "$web_service" --region="$region" --project="$project_id" --format='value(status.url)')"
[[ -n "$web_url" ]] || { echo "Could not discover the deployed web URL" >&2; exit 1; }
echo "Web URL: $web_url"
if [[ -z "$oidc_client_id" ]]; then
  echo "OIDC is not enabled yet. Create a Google OAuth client with this redirect URI, then rerun with --oidc-client-id and --oidc-client-secret:"
  echo "  $web_url/oidc/callback"
fi

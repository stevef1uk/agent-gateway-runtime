#!/usr/bin/env bash
# End-to-end encrypted Lambda image deployment for the Agent Gateway AWS weather demo.
# Uses an explicitly reviewed _l ARM64 release manifest, uploads activation objects
# to private versioned S3, imports verified digests into regional ECR, deploys
# deploy/aws/serverless-images.template.json, saves the teardown inventory, runs
# HTTP boundary smoke checks, and invites the Cognito operator.
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

AWS_PROFILE="${AWS_PROFILE:-agent-gateway-dev}"
AWS_REGION="${AWS_REGION:-eu-west-3}"
AWS_DEFAULT_REGION="$AWS_REGION"
export AWS_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_PAGER=""

AGW_ACCOUNT="${AGW_ACCOUNT:-}"
# Auto-detect AWS account ID from CLI profile if not explicitly set
if [ -z "$AGW_ACCOUNT" ]; then
  AGW_ACCOUNT=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --query Account --output text 2>/dev/null || echo "unknown")
fi
AGW_ARTIFACT_STACK="${AGW_ARTIFACT_STACK:-agent-gateway-artifacts-dev}"
AGW_APP_STACK="${AGW_APP_STACK:-agent-gateway-dev}"
AGW_UPSTREAM="${AGW_UPSTREAM:-https://api.open-meteo.com}"
AGW_RELEASE_MANIFEST="${AGW_RELEASE_MANIFEST:-}"
AGW_CUSTOMER_KEY_FILE="${AGW_CUSTOMER_KEY_FILE:-keys/local-activation/customer_private.pem}"
AGW_LICENCE_DIR="${AGW_LICENCE_DIR:-keys/local-activation/licences}"
AGW_DOMAIN_PREFIX="${AGW_DOMAIN_PREFIX:-}"
AGW_ADMIN_EMAILS="${AGW_ADMIN_EMAILS:-}"
AGW_WORKLOAD_BOUNDARY_ARN="${AGW_WORKLOAD_BOUNDARY_ARN:-}"
SKIP_ECR_PUSH=0

usage() {
  cat <<'EOF'
Usage:
  bash scripts/deploy-aws-weather-demo.sh \
    --release-manifest <reviewed-release.json> \
    --domain-prefix <unique-cognito-prefix> \
    --admin-emails <operator@example.com> \
    --workload-boundary-arn <WorkloadBoundaryArn-from-your-access-stack> \
    [--profile agent-gateway-dev] \
    [--skip-ecr-push]

Environment equivalents:
  AGW_RELEASE_MANIFEST, AGW_DOMAIN_PREFIX, AGW_ADMIN_EMAILS, AGW_WORKLOAD_BOUNDARY_ARN, AWS_PROFILE
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release-manifest) AGW_RELEASE_MANIFEST="${2:-}"; shift 2 ;;
    --domain-prefix) AGW_DOMAIN_PREFIX="${2:-}"; shift 2 ;;
    --admin-emails) AGW_ADMIN_EMAILS="${2:-}"; shift 2 ;;
    --workload-boundary-arn) AGW_WORKLOAD_BOUNDARY_ARN="${2:-}"; shift 2 ;;
    --profile) AWS_PROFILE="${2:-}"; export AWS_PROFILE; shift 2 ;;
    --skip-ecr-push) SKIP_ECR_PUSH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

for tool in aws docker python3 curl; do
  command -v "$tool" >/dev/null 2>&1 || die "Required tool not found: $tool"
done

[[ "$AGW_ACCOUNT" =~ ^[0-9]{12}$ ]] || die "Set AWS_ACCOUNT in aws-config.mk (or AGW_ACCOUNT) to your 12-digit deployment account"
[[ "$AWS_REGION" == "eu-west-3" ]] || die "Region must be eu-west-3 (Paris)"
[[ -n "$AGW_RELEASE_MANIFEST" ]] || die "Choose --release-manifest for the rebuilt console; no old image release is selected automatically"
[[ -f "$AGW_RELEASE_MANIFEST" ]] || die "Missing release manifest: $AGW_RELEASE_MANIFEST"
[[ -f "$AGW_CUSTOMER_KEY_FILE" ]] || die "Missing customer private key file: $AGW_CUSTOMER_KEY_FILE"
for svc in authz tokensvc gateway web; do
  [[ -f "$AGW_LICENCE_DIR/$svc.token" ]] || die "Missing service licence file: $AGW_LICENCE_DIR/$svc.token"
done

python3 -B scripts/aws-release.py "$AGW_RELEASE_MANIFEST"

python3 -B scripts/check-aws-activation.py --key "$AGW_CUSTOMER_KEY_FILE" --licences "$AGW_LICENCE_DIR"

say "Checking AWS identity (profile: $AWS_PROFILE, region: $AWS_REGION)"
caller_account="$(aws sts get-caller-identity --query Account --output text)"
caller_arn="$(aws sts get-caller-identity --query Arn --output text)"
[[ "$caller_arn" != *:root ]] || die "Use the configured non-root deployment role, not root credentials"
printf 'Caller ARN: %s (Account: %s)\n' "$caller_arn" "$caller_account"
[[ "$caller_account" == "$AGW_ACCOUNT" ]] || die "Expected AWS account $AGW_ACCOUNT, got $caller_account"

say "Checking deployment role CloudFormation permissions in $AWS_REGION"
set +e
cfn_check_output="$(aws cloudformation describe-stacks --stack-name "$AGW_ARTIFACT_STACK" 2>&1)"
cfn_check_rc=$?
set -e
if [[ $cfn_check_rc -ne 0 ]] && grep -q "AccessDenied" <<<"$cfn_check_output"; then
  cat >&2 <<EOF

================================================================================
ADMINISTRATOR PREREQUISITE REQUIRED:
The role '$caller_arn' does not yet have deployment permissions attached.

As documented in docs/Deployment-Guide.md, an administrator must first
deploy 'deploy/aws/deployment-access.template.json' in eu-west-3:

  1. Sign in as an administrator (Console or explicit admin CLI profile) in Paris (eu-west-3).
  2. Create stack 'agent-gateway-access-dev' from:
       $REPO_ROOT/deploy/aws/deployment-access.template.json
     with parameters:
       DeploymentRole=AgentGatewayDev
       ApplicationStack=$AGW_APP_STACK
       ArtifactStack=$AGW_ARTIFACT_STACK
  3. Copy the stack output 'WorkloadBoundaryArn' and re-run this script with:
       --workload-boundary-arn <WorkloadBoundaryArn>
================================================================================
EOF
  exit 1
fi

if [[ -z "$AGW_WORKLOAD_BOUNDARY_ARN" ]]; then
  die "Missing --workload-boundary-arn (or AGW_WORKLOAD_BOUNDARY_ARN) from stack agent-gateway-access-dev"
fi
if [[ -z "$AGW_DOMAIN_PREFIX" ]]; then
  die "Missing --domain-prefix (or AGW_DOMAIN_PREFIX) for Cognito hosted UI"
fi
if [[ -z "$AGW_ADMIN_EMAILS" ]]; then
  die "Missing --admin-emails (or AGW_ADMIN_EMAILS) for operator allowlist"
fi

[[ -n "${AGW_DEMO_DEPLOYMENT_ROLE_ARN:-}" ]] || die "Set DEMO_DEPLOYMENT_ROLE_ARN from access-stack outputs"

say "Checking live IAM prerequisites before deployment writes"
python3 -B scripts/check-aws-deployment-access.py \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --stack "$AGW_APP_STACK" --boundary "$AGW_WORKLOAD_BOUNDARY_ARN"

PLAN_DIR="$REPO_ROOT/dist/aws-lambda/plan"
mkdir -p "$PLAN_DIR"
RELEASE_TAG="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"][:12])' "$AGW_RELEASE_MANIFEST")"

# ---------------------------------------------------------------------------
# 1. Artifact Store Stack (agent-gateway-artifacts-dev)
# ---------------------------------------------------------------------------
say "1/6 Ensuring artifact store stack '$AGW_ARTIFACT_STACK' exists"
if aws cloudformation describe-stacks --stack-name "$AGW_ARTIFACT_STACK" >/dev/null 2>&1; then
  printf 'Stack %s already exists.\n' "$AGW_ARTIFACT_STACK"
else
  cs_name="agent-gateway-artifacts-${RELEASE_TAG}"
  aws cloudformation create-change-set \
    --stack-name "$AGW_ARTIFACT_STACK" \
    --change-set-name "$cs_name" \
    --change-set-type CREATE \
    --template-body file://deploy/aws/artifact-store.template.json
  aws cloudformation wait change-set-create-complete \
    --stack-name "$AGW_ARTIFACT_STACK" \
    --change-set-name "$cs_name"
  aws cloudformation execute-change-set \
    --stack-name "$AGW_ARTIFACT_STACK" \
    --change-set-name "$cs_name"
  aws cloudformation wait stack-create-complete \
    --stack-name "$AGW_ARTIFACT_STACK"
fi

agw_bucket="$(aws cloudformation describe-stacks \
  --stack-name "$AGW_ARTIFACT_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`ArtifactBucket`].OutputValue | [0]' \
  --output text)"
[[ -n "$agw_bucket" && "$agw_bucket" != "None" ]] || die "Could not resolve ArtifactBucket output from $AGW_ARTIFACT_STACK"
printf 'Artifact bucket: %s\n' "$agw_bucket"

# ---------------------------------------------------------------------------
# 2. Upload Private Versioned Activation Objects (SSE-S3)
# ---------------------------------------------------------------------------
say "2/6 Ensuring activation key and service licences exist in s3://$agw_bucket/activation/"
upload_or_reuse_versioned_object() {
  local src_file="$1" s3_key="$2"
  local checksum existing_ver existing_checksum
  checksum="$(python3 -c 'import base64,hashlib,pathlib,sys; print(base64.b64encode(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).digest()).decode())' "$src_file")"
  existing_ver="$(aws s3api head-object --bucket "$agw_bucket" --key "$s3_key" --query VersionId --output text 2>/dev/null || true)"
  existing_checksum="$(aws s3api head-object --bucket "$agw_bucket" --key "$s3_key" --checksum-mode ENABLED --query ChecksumSHA256 --output text 2>/dev/null || true)"
  if [[ -n "$existing_ver" && "$existing_ver" != "null" && "$existing_ver" != "None" && "$existing_checksum" == "$checksum" ]]; then
    printf '%s' "$existing_ver"
    return 0
  fi
  local ver
  ver="$(aws s3api put-object \
    --bucket "$agw_bucket" \
    --key "$s3_key" \
    --body "$src_file" \
    --server-side-encryption AES256 \
    --checksum-algorithm SHA256 \
    --checksum-sha256 "$checksum" \
    --query VersionId --output text)"
  [[ -n "$ver" && "$ver" != "null" && "$ver" != "None" ]] || die "Failed to obtain S3 VersionId for $s3_key"
  printf '%s' "$ver"
}

key_version="$(upload_or_reuse_versioned_object "$AGW_CUSTOMER_KEY_FILE" "activation/customer.key")"
printf 'Activation key activation/customer.key (VersionId: %s)\n' "$key_version"

authz_lic_version="$(upload_or_reuse_versioned_object "$AGW_LICENCE_DIR/authz.token" "activation/authz.token")"
tokensvc_lic_version="$(upload_or_reuse_versioned_object "$AGW_LICENCE_DIR/tokensvc.token" "activation/tokensvc.token")"
gateway_lic_version="$(upload_or_reuse_versioned_object "$AGW_LICENCE_DIR/gateway.token" "activation/gateway.token")"
web_lic_version="$(upload_or_reuse_versioned_object "$AGW_LICENCE_DIR/web.token" "activation/web.token")"
printf 'Service licences (VersionIds: authz=%s tokensvc=%s gateway=%s web=%s)\n' \
  "$authz_lic_version" "$tokensvc_lic_version" "$gateway_lic_version" "$web_lic_version"

# ---------------------------------------------------------------------------
# 3. Import Encrypted _l Images from Docker Hub into Regional Private ECR
# ---------------------------------------------------------------------------
say "3/6 Importing encrypted _l ARM64 images into private ECR ($AWS_REGION)"
ecr_registry="${AGW_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"
release_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$AGW_RELEASE_MANIFEST")"

if [[ "$SKIP_ECR_PUSH" -eq 0 ]]; then
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ecr_registry"
fi

get_service_manifest_field() {
  local svc="$1" field="$2"
  python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print((m["emotion"] if sys.argv[2]=="emotion" else m["images"][sys.argv[2]])[sys.argv[3]])' \
    "$AGW_RELEASE_MANIFEST" "$svc" "$field"
}

for svc in authz tokensvc gateway web emotion; do
  ecr_repo="${AGW_APP_STACK}/${svc}"
  expected_digest="$(get_service_manifest_field "$svc" "digest")"
  source_image="$(get_service_manifest_field "$svc" "immutable_image")"
  target_tag="${ecr_registry}/${ecr_repo}:${release_version}"

  if ! aws ecr describe-repositories --repository-names "$ecr_repo" >/dev/null 2>&1; then
    printf 'Creating ECR repository %s...\n' "$ecr_repo"
    aws ecr create-repository \
      --repository-name "$ecr_repo" \
      --image-tag-mutability IMMUTABLE \
      --image-scanning-configuration scanOnPush=true >/dev/null
  fi

  if [[ "$SKIP_ECR_PUSH" -eq 0 ]]; then
    if aws ecr describe-images --repository-name "$ecr_repo" --image-ids "imageDigest=$expected_digest" >/dev/null 2>&1; then
      printf 'ECR repository %s already has verified digest %s\n' "$ecr_repo" "$expected_digest"
    else
      printf 'Pulling %s (linux/arm64) and pushing to %s...\n' "$source_image" "$target_tag"
      docker pull --platform linux/arm64 "$source_image"
      docker tag "$source_image" "$target_tag"
      docker push "$target_tag"
    fi
  fi

  actual_digest="$(aws ecr describe-images \
    --repository-name "$ecr_repo" \
    --image-ids "imageDigest=$expected_digest" \
    --query 'imageDetails[0].imageDigest' --output text)"
  [[ "$actual_digest" == "$expected_digest" ]] || die "ECR digest mismatch for $ecr_repo: expected $expected_digest, got $actual_digest"
  printf 'Verified ECR image: %s/%s@%s\n' "$ecr_registry" "$ecr_repo" "$actual_digest"
done

# ---------------------------------------------------------------------------
# 4. Generate Release Configuration & CloudFormation Parameters
# ---------------------------------------------------------------------------
say "4/6 Generating release-config.json and parameters.json"
authz_digest="$(get_service_manifest_field authz digest)"
tokensvc_digest="$(get_service_manifest_field tokensvc digest)"
gateway_digest="$(get_service_manifest_field gateway digest)"
web_digest="$(get_service_manifest_field web digest)"
emotion_digest="$(get_service_manifest_field emotion digest)"
AGW_EMOTION_IMAGE_URI="$ecr_registry/$AGW_APP_STACK/emotion@$emotion_digest"

python3 - "$PLAN_DIR/release-config.json" "$AGW_ACCOUNT" "$AWS_REGION" \
  "$AGW_WORKLOAD_BOUNDARY_ARN" "$agw_bucket" "$key_version" \
  "$AGW_DOMAIN_PREFIX" "$AGW_ADMIN_EMAILS" "$AGW_UPSTREAM" "$ecr_registry" "$AGW_APP_STACK" \
  "$authz_digest" "$tokensvc_digest" "$gateway_digest" "$web_digest" \
  "$authz_lic_version" "$tokensvc_lic_version" "$gateway_lic_version" "$web_lic_version" "${AGW_EMOTION_IMAGE_URI:-}" "${AGW_DEMO_DEPLOYMENT_ROLE_ARN:-}" <<'PYCONFIG'
import json, sys
(out, account, region, boundary, bucket, key_version, domain, emails, upstream,
 registry, stack, *versions) = sys.argv[1:]
services = ['authz','tokensvc','gateway','web']
config = dict(account=account, region=region, workload_boundary_arn=boundary,
 activation=dict(bucket=bucket, key_object='activation/customer.key', key_version=key_version),
 domain_prefix=domain, admin_emails=emails, upstream_url=upstream, weather_demo=True,
 services={service:dict(image_uri=f'{registry}/{stack}/{service}@{versions[index]}',
 licence_object=f'activation/{service}.token', licence_version=versions[index+4])
 for index, service in enumerate(services)})
config.update(app_stack=stack, emotion_image_uri=versions[8], demo_deployment_role_arn=versions[9])
with open(out, 'w') as f:
 json.dump(config, f, indent=2)
 f.write('\n')
PYCONFIG

python3 -B scripts/prepare-aws-image-deployment.py \
  "$PLAN_DIR/release-config.json" \
  "$PLAN_DIR/parameters.json"

say "4b/6 Preparing deploy-time secrets (NoEcho, no Secrets Manager)"
secrets_file="$PLAN_DIR/secrets.json"
python3 - "$secrets_file" "$PLAN_DIR/parameters.json" <<'PYSECRETS'
import json, os, secrets, sys
path, params_path = sys.argv[1], sys.argv[2]
if os.path.exists(path):
    with open(path) as f:
        data = json.load(f)
else:
    alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
    data = {
        'jwt': ''.join(secrets.choice(alphabet) for _ in range(64)),
        'admin': ''.join(secrets.choice(alphabet) for _ in range(64)),
    }
    tmp = path + '.tmp'
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    os.replace(tmp, path)
with open(params_path) as f:
    params = json.load(f)
params = [p for p in params if p.get('ParameterKey') not in ('JWTSecretValue', 'AdminSecretValue')]
params.append({'ParameterKey': 'JWTSecretValue', 'ParameterValue': data['jwt']})
params.append({'ParameterKey': 'AdminSecretValue', 'ParameterValue': data['admin']})
os.chmod(params_path, 0o600)
with open(params_path, 'w') as f:
    json.dump(params, f, indent=2)
    f.write('\n')
PYSECRETS

# ---------------------------------------------------------------------------
# 5. Deploy Application Stack (deploy/aws/serverless-images.template.json)
# ---------------------------------------------------------------------------
say "5/6 Uploading template (>51.2 KB) to S3, validating, and deploying '$AGW_APP_STACK'"
template_key="templates/serverless-images-${RELEASE_TAG}.template.json"
template_checksum="$(python3 -c 'import base64,hashlib,pathlib,sys; print(base64.b64encode(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).digest()).decode())' "deploy/aws/serverless-images.template.json")"
template_ver="$(aws s3api put-object \
  --bucket "$agw_bucket" \
  --key "$template_key" \
  --body "deploy/aws/serverless-images.template.json" \
  --server-side-encryption AES256 \
  --checksum-algorithm SHA256 \
  --checksum-sha256 "$template_checksum" \
  --query VersionId --output text)"
template_url="https://${agw_bucket}.s3.${AWS_REGION}.amazonaws.com/${template_key}?versionId=${template_ver}"

aws cloudformation validate-template \
  --template-url "$template_url" >/dev/null

cs_type="CREATE"
wait_target="stack-create-complete"
if aws cloudformation describe-stacks --stack-name "$AGW_APP_STACK" >/dev/null 2>&1; then
  stack_status="$(aws cloudformation describe-stacks --stack-name "$AGW_APP_STACK" --query 'Stacks[0].StackStatus' --output text)"
  if [[ "$stack_status" != "REVIEW_IN_PROGRESS" ]]; then
    cs_type="UPDATE"
    wait_target="stack-update-complete"
  fi
fi

app_cs_name="agent-gateway-app-${RELEASE_TAG}-$(date +%s)"
aws cloudformation create-change-set \
  --stack-name "$AGW_APP_STACK" \
  --change-set-name "$app_cs_name" \
  --change-set-type "$cs_type" \
  --template-url "$template_url" \
  --parameters "file://$PLAN_DIR/parameters.json" \
  --capabilities CAPABILITY_IAM

if aws cloudformation wait change-set-create-complete \
  --stack-name "$AGW_APP_STACK" --change-set-name "$app_cs_name"; then
  aws cloudformation execute-change-set \
    --stack-name "$AGW_APP_STACK" --change-set-name "$app_cs_name"
  aws cloudformation wait "$wait_target" --stack-name "$AGW_APP_STACK"
else
  change_reason="$(aws cloudformation describe-change-set --stack-name "$AGW_APP_STACK" --change-set-name "$app_cs_name" --query StatusReason --output text)"
  if [[ "$change_reason" == *"didn't contain changes"* || "$change_reason" == *"No updates"* ]]; then
    printf 'Application stack already matches the selected release.\n'
    aws cloudformation delete-change-set --stack-name "$AGW_APP_STACK" --change-set-name "$app_cs_name"
  else
    printf 'Change-set validation failed: %s\n' "$change_reason" >&2
    aws cloudformation describe-events --stack-name "$AGW_APP_STACK" --change-set-name "$app_cs_name" || true
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 6. Teardown Inventory, Boundary Checks & Cognito Invitation
# ---------------------------------------------------------------------------
say "6/6 Saving teardown inventory, running HTTP boundary checks, and inviting Cognito user"
python3 scripts/teardown-aws-deployment.py --profile "$AWS_PROFILE" --region "$AWS_REGION" --app-stack "$AGW_APP_STACK" --artifact-stack "$AGW_ARTIFACT_STACK" --account "$AGW_ACCOUNT"

agw_console="$(aws cloudformation describe-stacks --stack-name "$AGW_APP_STACK" --query 'Stacks[0].Outputs[?OutputKey==`ConsoleURL`].OutputValue | [0]' --output text)"
agw_gateway="$(aws cloudformation describe-stacks --stack-name "$AGW_APP_STACK" --query 'Stacks[0].Outputs[?OutputKey==`GatewayURL`].OutputValue | [0]' --output text)"
agw_pool="$(aws cloudformation describe-stacks --stack-name "$AGW_APP_STACK" --query 'Stacks[0].Outputs[?OutputKey==`UserPoolId`].OutputValue | [0]' --output text)"
agw_authz_api="$(aws cloudformation describe-stack-resource --stack-name "$AGW_APP_STACK" --logical-resource-id AuthzAPI --query StackResourceDetail.PhysicalResourceId --output text)"
agw_token_api="$(aws cloudformation describe-stack-resource --stack-name "$AGW_APP_STACK" --logical-resource-id TokensvcAPI --query StackResourceDetail.PhysicalResourceId --output text)"
agw_internal_api="$(aws cloudformation describe-stack-resource --stack-name "$AGW_APP_STACK" --logical-resource-id GatewayInternalAPI --query StackResourceDetail.PhysicalResourceId --output text)"

printf 'Verifying public health and OAuth discovery...\n'
curl -fsS "$agw_console/healthz" >/dev/null
curl -fsS "$agw_gateway/healthz" >/dev/null
curl -fsS "$agw_gateway/.well-known/oauth-authorization-server" >/dev/null

unauth_delegations="$(curl -sS -o /dev/null -w '%{http_code}' "$agw_console/api/delegations")"
[[ "$unauth_delegations" == "401" ]] || die "Expected 401 on unauthenticated $agw_console/api/delegations, got $unauth_delegations"

spoof_code="$(curl -sS -o /dev/null -w '%{http_code}' -H 'X-Agent-Gateway-Authorization: Bearer invalid' "$agw_gateway/mcp")"
[[ "$spoof_code" == "403" ]] || die "Expected 403 on spoofed envelope to $agw_gateway/mcp, got $spoof_code"

for api_id in "$agw_authz_api" "$agw_token_api" "$agw_internal_api"; do
  internal_code="$(curl -sS -o /dev/null -w '%{http_code}' "https://${api_id}.execute-api.${AWS_REGION}.amazonaws.com/healthz")"
  [[ "$internal_code" == "403" ]] || die "Expected 403 on unsigned internal API $api_id, got $internal_code"
done
printf 'PASS: All public/internal HTTP boundary checks succeeded.\n'

primary_email="${AGW_ADMIN_EMAILS%%,*}"
if aws cognito-idp admin-get-user --user-pool-id "$agw_pool" --username "$primary_email" >/dev/null 2>&1; then
  printf 'Cognito user %s already exists in pool %s.\n' "$primary_email" "$agw_pool"
else
  printf 'Inviting Cognito operator user %s...\n' "$primary_email"
  aws cognito-idp admin-create-user \
    --user-pool-id "$agw_pool" \
    --username "$primary_email" \
    --user-attributes "Name=email,Value=$primary_email" "Name=email_verified,Value=true" \
    --desired-delivery-mediums EMAIL >/dev/null
fi

cat >"$PLAN_DIR/deployment-outputs.env" <<EOF
CONSOLE_URL='${agw_console}'
GATEWAY_URL='${agw_gateway}'
USER_POOL_ID='${agw_pool}'
OPERATOR_EMAIL='${primary_email}'
EOF

cat <<EOF

================================================================================
Deployment Complete!
  ConsoleURL:    $agw_console
  GatewayURL:    $agw_gateway
  UserPoolId:    $agw_pool
  Operator:      $primary_email
  Outputs file:  $PLAN_DIR/deployment-outputs.env

Next: Open ConsoleURL and complete your email invitation, then follow:
  docs/Deployment-Guide.md
  make aws-demo-url DEMO=users
================================================================================
EOF

#!/usr/bin/env bash
# Explicitly deletes only this application's known demo/runtime repositories.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-agent-gateway-dev}" AWS_REGION="${AWS_REGION:-eu-west-3}" AWS_PAGER=""
stack="${AWS_STACK:-agent-gateway-dev}"
[[ "$stack" =~ ^agent-gateway-[a-z0-9-]+$ ]] || { echo 'Invalid application stack prefix.' >&2; exit 2; }
account="$(aws sts get-caller-identity --query Account --output text)"
[[ "${CONFIRM_ACCOUNT:-}" == "$account" ]] || { echo 'CONFIRM_ACCOUNT must match the selected AWS account.' >&2; exit 2; }
for service in authz tokensvc gateway web emotion; do
 repo="$stack/$service"
 if result="$(aws ecr delete-repository --repository-name "$repo" --force 2>&1)"; then
  printf 'Deleted %s\n' "$repo"
 elif [[ "$result" == *RepositoryNotFoundException* ]]; then
  printf 'Already absent: %s\n' "$repo"
 else
  printf '%s\n' "$result" >&2; exit 1
 fi
done

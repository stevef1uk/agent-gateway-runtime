#!/usr/bin/env bash
# Optional vendor-token delivery; this script does not create, inspect or validate licences.
set -euo pipefail
[[ -n "${TOKEN_FILE:-}" && -f "$TOKEN_FILE" ]] || { echo 'Set TOKEN_FILE to the purchased Emotion token file.' >&2; exit 2; }
export AWS_PROFILE="${AWS_PROFILE:-agent-gateway-dev}" AWS_REGION="${AWS_REGION:-eu-west-3}" AWS_PAGER=""
stack="${AWS_STACK:-agent-gateway-dev}"
bucket="$(aws cloudformation describe-stacks --stack-name "$stack" --query 'Stacks[0].Parameters[?ParameterKey==`ActivationBucket`].ParameterValue | [0]' --output text)"
[[ -n "$bucket" && "$bucket" != None ]] || { echo 'Could not find the application activation bucket.' >&2; exit 1; }
aws s3api put-object --bucket "$bucket" --key activation/emotion.token --body "$TOKEN_FILE" \
 --server-side-encryption AES256 --checksum-algorithm SHA256 --query VersionId --output text

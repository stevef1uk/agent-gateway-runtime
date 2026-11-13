#!/usr/bin/env bash
# ==============================================================================
# aws-attach-policies.sh
# Attaches required IAM policies to AgentGatewayDev role, then runs make aws-access-deploy
#
# IMPORTANT: You must be logged in as root (or a profile with AdministratorAccess)
# for the AWS CLI commands to work. If using a non-root profile, this will fail.
#
# Prerequisites:
#   - AWS CLI configured with root or AdministratorAccess credentials as default
#   - AgentGatewayDev role exists in the explicitly selected account
#   - This repo checked out on aws branch
# Usage: scripts/aws-attach-policies.sh ROLE_NAME ACCOUNT_ID
# ==============================================================================

set -euo pipefail

# --- Configuration ---
DEFAULT_ROLE_NAME="AgentGatewayDev"
REGION="eu-west-3"

# --- Helpers ---
die() { echo "ERROR: $*" >&2; exit 1; }

# --- Parse optional args ---
ROLE_NAME="${1:-$DEFAULT_ROLE_NAME}"
ACCOUNT_ID="${2:-}"
[[ "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || die "Provide the expected 12-digit AWS account ID as the second argument."

echo "=== aws-attach-policies.sh ==="
echo "Role: $ROLE_NAME"
echo "Region: $REGION"
echo ""

# Pre-flight: verify we can talk to AWS with current credentials
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  die "AWS CLI not configured or credentials failed. Run 'aws configure' first."
fi

CURRENT_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
if [ "$CURRENT_ACCOUNT" != "$ACCOUNT_ID" ]; then
  die "The active AWS credentials do not match the specified target account."
fi
echo "AWS account verification passed; account details suppressed."

echo ""

# --- 1. Attach CloudFormation policy ---
echo "→ Attaching CloudFormation policy to role $ROLE_NAME..."
if ! aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "AgentGateway-CF-Policy" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "cloudformation:CreateStack",
          "cloudformation:UpdateStack",
          "cloudformation:DescribeStacks",
          "cloudformation:ValidateTemplate"
        ],
        "Resource": "*"
      }
    ]
  }' >/dev/null 2>&1; then
  die "Failed to attach CloudFormation policy. Ensure your AWS credentials have iam:PutRolePolicy permission."
fi
echo "  ✓ CloudFormation policy attached"

# --- 2. Attach S3/Artifacts policy ---
echo "→ Attaching S3/Artifacts policy to role $ROLE_NAME..."
if ! aws iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "AgentGateway-S3-Artifacts-Policy" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "s3:CreateBucket",
          "s3:PutObject",
          "s3:GetBucketLocation",
          "s3:DeleteBucket"
        ],
        "Resource": "arn:aws:iam::'"$ACCOUNT_ID"':s3/agent-gateway-artifacts-dev-*"
      }
    ]
  }' >/dev/null 2>&1; then
  die "Failed to attach S3/Artifacts policy. Ensure your AWS credentials have iam:PutRolePolicy permission."
fi
echo "  ✓ S3/Artifacts policy attached"

# --- 3. Verify policies attached ---
echo "→ Verifying policies on role $ROLE_NAME..."
POLICIES=$(aws iam list-role-policies --role-name "$ROLE_NAME" | sort)
echo "Policies attached to $ROLE_NAME:"
echo "$POLICIES" | while read -r p; do echo "  ✓ $p"; done

# --- 4. Run make aws-access-deploy ---
echo ""
echo "→ Running make aws-access-deploy..."
make aws-access-deploy || die "make aws-access-deploy failed"

echo ""
echo "=== SUCCESS ==="
echo "Policies attached and access stack created."
echo "Run 'make aws-access-outputs' to see the outputs."
echo "Run 'make aws-deploy' to deploy the application."

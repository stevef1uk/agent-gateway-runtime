# ============================================================================
# aws-config.mk — Copy to local file and edit. Git-ignored; do not commit credentials.
# ============================================================================

# Deployment region (Paris is the only supported region for this workflow).
AWS_REGION = eu-west-3

# Named CLI profile assuming your existing non-root deployment role.
# Default: agent-gateway-dev  (create this in ~/.aws/credentials or export AWS_PROFILE)
AWS_PROFILE = agent-gateway-dev

# Your own 12-digit AWS account ID (not the vendor's).
# Required: replace with your actual account number before running make aws-identity.
AWS_ACCOUNT = YOUR_AWS_ACCOUNT_ID    # e.g. 111111111111 (replace with your actual account)

# Existing IAM role name assumed by AWS_PROFILE.
# Default: AgentGatewayDev  (admin: create this role with trust policy before deployment)
AWS_DEPLOYMENT_ROLE_NAME = AgentGatewayDev

# Separate administrator profile used ONLY for access setup/deletion.
# This profile must have IAM attach-policy and CloudFormation stack creation
# permissions in your AWS account. It is strictly separate from the deployer
# profile (AWS_PROFILE) and should not have AdministratorAccess attached to
# the application role.
#
# Create in ~/.aws/credentials (or your AWS config directory):
#
#   [admin-gateway-dev]
#   source_profile = your-personal-or-admin-profile
#
#   # Or with assumed role (if the profile itself is not an IAM user):
#   # role_arn = arn:aws:iam::YOUR_ACCOUNT:role/AgentGatewayDev
#   # source_profile = your-personal-or-admin-profile
#
# Default: leave blank, set via AWS_ADMIN_PROFILE env var, or set a name
# like 'admin-gateway-dev' that maps to a profile with sufficient permissions.
AWS_ADMIN_PROFILE =

# Stack names for your isolated deployment.
# These are suggestions; agree consistent names with your administrator if deploying in a shared account.
AWS_STACK = agent-gateway-dev
AWS_ARTIFACT_STACK = agent-gateway-artifacts-dev
AWS_ACCESS_STACK = agent-gateway-access-dev

# Path to the current vendor-published schema-2 release manifest.
# Included in this repo's aws branch: releases/current.json
RELEASE_MANIFEST = releases/current.json

# Local signed licences for the four services. The customer key is for optional Emotion activation.
CUSTOMER_KEY_FILE = keys/local-activation/customer_private.pem
VENDOR_PUBLIC_KEY_FILE = keys/local-activation/vendor_public.pem
LICENCE_DIR = keys/local-activation/licences

# Choose a unique lowercase Cognito domain prefix.
# Must be globally unique across all of AWS. Format: your-org-name-random-suffix
# Example: agent-gateway-demo-abc123
DOMAIN_PREFIX = agent-gateway-demo

# Your real reachable operator email(s).
# Comma-separated without spaces. Used for Cognito invitation emails.
# Example: admin1@example.com,admin2@example.com
ADMIN_EMAILS = admin@example.com

# Copy this exact identifier from `make aws-access-outputs` after admin setup.
# Populated automatically by the access stack; leave blank until after step 5.
WORKLOAD_BOUNDARY_ARN =

# Optional proxy only: reviewed non-root EC2/IAM/SSM provisioning profile.
# Not used in the core workflow (proxy VM is optional infrastructure).
AWS_VM_PROFILE =

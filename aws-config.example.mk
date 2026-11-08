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
AWS_ACCOUNT =

# Existing IAM role name assumed by AWS_PROFILE.
# Default: AgentGatewayDev  (admin: create this role with trust policy before deployment)
AWS_DEPLOYMENT_ROLE_NAME = AgentGatewayDev

# Separate administrator profile used ONLY for access setup/deletion.
# Create a non-admin profile with iam:AttachPolicy, iam:PutRolePolicy, cloudformation:CreateStack etc.
# Default: leave blank and set via AWS_ADMIN_PROFILE env var, or set a name like admin-gateway-dev
AWS_ADMIN_PROFILE =

# Stack names for your isolated deployment.
# These are suggestions; agree consistent names with your administrator if deploying in a shared account.
AWS_STACK = agent-gateway-dev
AWS_ARTIFACT_STACK = agent-gateway-artifacts-dev
AWS_ACCESS_STACK = agent-gateway-access-dev

# Path to the current vendor-published schema-2 release manifest.
# Included in this repo's aws branch: releases/current.json
RELEASE_MANIFEST = releases/current.json

# Existing local activation material compatible with the published images.
# Create keys/ directory and place your customer private key and licence .token files there.
CUSTOMER_KEY_FILE = keys/customer_private.pem
LICENCE_DIR = keys/licences

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

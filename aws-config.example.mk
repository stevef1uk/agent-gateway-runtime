# Copy to aws-config.mk and edit that local file. Do not put credentials here.
# Paris is currently the supported deployment region.
AWS_REGION = eu-west-3
# Named CLI profile assuming your existing non-root deployment role.
AWS_PROFILE = agent-gateway-dev
# Your own 12-digit AWS account, not the vendor's account.
AWS_ACCOUNT =
# Existing IAM role name used by AWS_PROFILE (ask your AWS administrator).
AWS_DEPLOYMENT_ROLE_NAME = AgentGatewayDev
# Separate administrator profile used only for access setup/deletion.
AWS_ADMIN_PROFILE =
AWS_STACK = agent-gateway-dev
AWS_ARTIFACT_STACK = agent-gateway-artifacts-dev
AWS_ACCESS_STACK = agent-gateway-access-dev
# Path to the current vendor-published schema-2 release manifest you downloaded.
RELEASE_MANIFEST = releases/current.json
# Existing local activation material compatible with the published images.
CUSTOMER_KEY_FILE = keys/customer_private.pem
LICENCE_DIR = keys/licences
# Choose a unique lowercase Cognito domain prefix and your real email.
DOMAIN_PREFIX =
ADMIN_EMAILS =
# Copy this exact identifier from `make aws-access-outputs` after admin setup.
WORKLOAD_BOUNDARY_ARN =
# Optional proxy only: reviewed non-root EC2/IAM/SSM provisioning profile.
AWS_VM_PROFILE =

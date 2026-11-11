# GCP deployment security notes

Use only the Console URL and deployment resources created in your own GCP
project. The public web Console proxies governed requests to the Gateway; do
not give agents the private Gateway URL or the upstream provider URL.

Configure verified administrator emails when enabling Google sign-in. Keep
OAuth client secrets, delegation secrets, access tokens, licence tokens, and
private keys out of source control, URLs, and shared logs. Store deployment
secrets in the intended local secure files or Google Secret Manager.

Delegations should grant only the required resources, actions, limits, and
approval rules. Revoke test delegations when finished. Rego changes apply to
all Rego-enabled delegations in the deployment; validate changes and use the
Console's version history to roll back when needed.

See the [GCP deployment guide](./docs/GCP-Deployment-Guide.md) and
[GCP Console tutorial](./docs/GCP-Console-Tutorial.md) for deployment and
policy-management details.

# Security scope of the AWS weather demo

Use only the console/gateway URLs supplied by your own reviewed deployment. Do not
reuse local demo accounts, operator tokens, image keys or public management endpoints
from the `main` branch. This branch includes no credentials and no infrastructure
provisioning/teardown implementation; operator guides link to the authorized source
checkout. No historical security-scan result is claimed for these AWS artifacts.

Human sign-in is through Cognito. Delegation creation and decisions use the verified
server-side console session; agent curls need only a short-lived agent token. Never
commit passwords, cookies, human ID tokens, agent secrets/tokens, HAR files or private
keys. Revoke disposable delegations after testing and keep all account changes scoped.

The public weather provider must not receive gateway credentials, actor identity or
forwarding headers. The weather-enabled gateway release implements that stripping.
Caller mapping headers cannot turn a forbidden weather method/path into an allowed
one. Exact weather routes are public; management APIs remain IAM protected.

A $10 AWS Budget is not a hard cap. See docs/Teardown.md for retained resources and
irreversible purge choices. This branch has not yet passed real AWS deployment,
Cognito/API Gateway acceptance, load/fault testing or production HA validation.

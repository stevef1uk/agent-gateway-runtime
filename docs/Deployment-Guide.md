# Internal operator notes: AWS weather deployment

For the new encrypted-image path, use the operator
[image deployment guide](https://github.com/stevef1uk/agent-gateway/blob/aws/docs/aws/encrypted-lambda-images.md)
and `serverless-images.template.json`. The ZIP build steps below describe the earlier
source-only development prototype and are not a customer installation method.
Images use the separate `stevef1uk/agent-gateway-{authz,tokensvc,gateway,web}_l` names;
[initial versioned images are published](releases/0.1.0-aws-c506506.md), while
AWS acceptance and a complete customer installation bundle remain pending.

For ordinary users, start with the [weather walkthrough](Public-API-Curl-Tutorial.md).
For customer-owned infrastructure, start with [Self-hosting](Self-Hosting.md).
Marketplace delivery is covered in the separate [Marketplace guide](AWS-Marketplace.md).
The source links below are internal evaluation references, not third-party prerequisites.

This runtime branch is a client/demo guide. Infrastructure and private implementation
remain in `stevef1uk/agent-gateway`, branch `aws`. Authorized access to that repository
is currently required for provisioning; this is not yet a self-contained Marketplace
installer or buyer distribution. Do not deploy the old `main` branch's Compose/k3s stack
as an AWS substitute.

Use compatible source release **`c7e0906` or later**, with these authoritative guides:

- [Implementation status](https://github.com/stevef1uk/agent-gateway/blob/aws/docs/aws/README.md).
- [Exact deployment and cloud testing commands](https://github.com/stevef1uk/agent-gateway/blob/aws/docs/aws/deploy-and-test.md).
- [Weather-specific settings and acceptance](https://github.com/stevef1uk/agent-gateway/blob/aws/docs/aws/weather-demo.md).
- [Current resource/cost model](https://github.com/stevef1uk/agent-gateway/blob/aws/docs/aws/serverless-pricing.md).

## Operator prerequisites

Choose your reviewed account and region; the current evaluation target uses Paris
`eu-west-3`. A validation-only profile cannot provision or clean up the application.
Deployment/cleanup permissions and workload-role boundaries require review. No
application stack has been deployed; local passes are not AWS acceptance evidence.

A $10 monthly budget is a reasonable initial evaluation planning target. Check actual/forecast alerts;
an AWS Budget is not a hard spending cap. Do not create a paid Open-Meteo subscription
or enable extra services merely to run this small development scenario.

## Weather release settings

In the authorized source checkout, follow the source runbook's artifact-store,
immutable build/upload and change-set sequence. At its settings step:

```sh
agw_upstream='https://api.open-meteo.com'
export AWS_WEATHER_DEMO=1
```

Prepare the release after the artifact bucket exists:

```sh
AWS_WEATHER_DEMO=1 bash scripts/prepare-aws-deployment.sh \
  "$agw_bucket" "releases/$agw_release" "$agw_domain" "$agw_admin_emails" \
  https://api.open-meteo.com
```

This command is run in the **source repository**, not this runtime repository.
It writes `EnableWeatherDemo=true` in the reviewed parameters; it does not deploy.
The template defaults weather mode off and rejects another upstream with it on.

The source stack provides four ARM64 HTTP Lambdas, five HTTP APIs, DynamoDB,
Cognito, scoped workload roles, generated-secret references and logs. Weather
mode adds only three exact public routes: `/v1/forecast`, `/v1/elevation` and
`/v1/marine` (for the negative-scope probe). Management routes remain IAM-only;
there is no public `/v1/*` catch-all. Credentials and actor/forwarding headers are
stripped before the third-party weather hop. Caller mapping overrides cannot
change these routes' actual method/path authorization.

Review the artifact and application change sets before executing. Save the teardown
inventory immediately after deployment. Invite a test Cognito user at an email in
the allowlist; complete sign-in privately. Give demo users only ConsoleURL, the
public GatewayURL and their Cognito invitation—not AWS/admin secrets. Then follow
[the weather tutorial](Public-API-Curl-Tutorial.md) and the source runbook's unsigned
internal-route/spoofed-envelope checks. The complete real-AWS browser/DPoP/load/HA
acceptance suite is not yet automated or completed.

Keep `AWS_WEATHER_DEMO=1` when preparing updates that should retain weather ingress.
A new immutable release prefix is required for changed binaries. Disabling the flag
removes the three demo routes, not tables/audit/user data. Follow [teardown](Teardown.md)
for cleanup rather than weakening security or deleting data as a debugging shortcut.

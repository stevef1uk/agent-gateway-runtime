# AWS weather-demo costs

These are **modeled infrastructure costs**, not a hosted subscription quote or a
measured bill. Region Paris (`eu-west-3`), USD/month, rate snapshot 7 November 2026;
no shared free allowances or credits applied; tax excluded.

| Scenario | Estimated monthly infrastructure |
| --- | ---: |
| Idle, with small retained data/artifacts | $0.88 |
| 10,000 external requests | $1.65 |
| 100,000 external requests | $8.36 |
| 100,000 external requests, five-second mean invocation time | $19.02 |

The active scenarios assume four billed Lambda/API Gateway calls per external
request, 512 MiB functions and a one-second mean per invocation except the final
row. Billed time includes waiting for internal/upstream responses. The model includes
DynamoDB requests/storage/PITR, logs, two secrets, S3 artifact versions and requests,
Cognito Lite users and Internet egress. Storage/log/request assumptions vary with
scenario; these figures are not fixed-price offers or load-tested capacity promises.

No extra upstream VM, NAT, RDS or Redis is deployed for the weather scenario. The
three exact weather routes add no fixed monthly compute charge. Actual runtime,
request fan-out, retries, logs and retained data can raise costs; applicable shared
free allowances can reduce the bill. No paid support, custom domains, WAF, software
fees, Marketplace subscription, paid weather service or tax is included.

## Hosted use versus your own account

A hosted-demo user does not deploy these resources in their account. Any future
hosted/Marketplace software price must be published separately; none is quoted or
available here today. A self-hosting customer pays for their own AWS resources plus
any software/provider charges agreed with the release. See [Self-hosting](Self-Hosting.md)
and [Marketplace](AWS-Marketplace.md) for current availability.

A $10 AWS Budget is an alerting target, not a hard cap. Check actual and forecast
notifications; AWS billing/alerts can lag. Stack deletion can retain billable data,
secrets and artifact versions. Read [cleanup](Teardown.md) before self-hosting.

Open-Meteo's [pricing](https://open-meteo.com/en/pricing) supports evaluation/prototyping
under its current [terms](https://open-meteo.com/en/terms) and limits. Commercial/
promotional use needs an appropriate arrangement. The client creates no subscription
and should not load-test the public provider.

## Public price sources

The model uses current-at-review AWS regional rate dimensions, including ARM Lambda
compute/requests, HTTP API (not REST API), DynamoDB Standard on-demand requests/PITR,
CloudWatch Standard logs, Secrets Manager, S3 Standard and Cognito Lite:

- [Lambda Paris rates](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSLambda/current/eu-west-3/index.json).
- [HTTP API Paris rates](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonApiGateway/current/eu-west-3/index.json).
- [DynamoDB Paris rates](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonDynamoDB/current/eu-west-3/index.json).
- [CloudWatch Paris rates](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonCloudWatch/current/eu-west-3/index.json).
- [Secrets Manager Paris rates](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSSecretsManager/current/eu-west-3/index.json).
- [S3 Paris rates](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonS3/current/eu-west-3/index.json).
- [Cognito Paris rates](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonCognito/current/eu-west-3/index.json).
- [Data transfer Paris rates](https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSDataTransfer/current/eu-west-3/index.json).

A published self-hosting release must ship its exact usage inputs and reproducible
calculator alongside the deployment/teardown bundle, without requiring private
source access. That customer release bundle is still pending.

The existing infrastructure examples were modeled for development ZIPs. Customer
image deployment also incurs private ECR storage and activation S3 GET/storage
charges. Licence verification/decryption consumes billed cold-start duration; the
local 508 ms median is not an AWS measurement. A complete image release quote must
include these items, retained image versions and any software/source licence fee.


## Image evaluation planning

The operator model now adds private ECR storage, activation S3 GETs and cold-start
licence/decryption duration. With 2 GB-month registry storage, 10% cold service
invocations, two additional seconds of activation and the existing usage model:
idle is $1.08/month, 10,000 external actions $1.91 and 100,000 actions $9.12.
If base invocations average five seconds rather than one, 100,000 actions become
$19.79/month. These are assumptions before tax/software fees, not measured AWS
charges or a $10 cap. A short acceptance run has different storage/log usage.
See the [reproducible model and all assumptions](https://github.com/stevef1uk/agent-gateway/blob/aws/docs/aws/serverless-pricing.md#encrypted-image-deployment-preflight-7-november-2026).

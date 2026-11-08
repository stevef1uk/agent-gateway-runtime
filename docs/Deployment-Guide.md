# Operator Deployment Guide: Agent Gateway on AWS (`eu-west-3`)

> Recovery status (8 November 2026): console build **1.0.93** is repaired in source and still requires a new encrypted image release and live acceptance testing. Endpoint identifiers below are recorded deployment values; confirm current CloudFormation outputs before using them.

This guide summarizes how the **Agent Gateway AWS Serverless Edition** is deployed and updated in **Paris (`eu-west-3`)** from the authorized implementation repository (`stevef1uk/agent-gateway`, branch `aws`).

For running the demo as an operator or user against the live stack, start with [README.md](../README.md) or the [Weather Walkthrough](Public-API-Curl-Tutorial.md).

---

## 1. Live Deployed Stack Inventory (`eu-west-3`, Account `857710215813`)

| Resource | Deployed Identifier / URL |
|---|---|
| **Access Boundary Stack** | `agent-gateway-access-dev` (`deploy/aws/deployment-access.template.json`) |
| **Workload Boundary Policy** | `arn:aws:iam::857710215813:policy/agent-gateway-access-dev-WorkloadBoundary-cUd8zZCXC0P0` |
| **Artifact Store Stack** | `agent-gateway-artifacts-dev` (`deploy/aws/artifact-store.template.json`) |
| **Activation S3 Bucket** | `agent-gateway-artifacts-dev-artifacts-zxnumraqhjvy` (`activation/customer.key` + `activation/{authz,tokensvc,gateway,web}.token`) |
| **Application Stack** | `agent-gateway-dev` (`deploy/aws/serverless-images.template.json`) |
| **ECR Repositories** | `857710215813.dkr.ecr.eu-west-3.amazonaws.com/agent-gateway-dev/{authz,tokensvc,gateway,web}` |
| **Lambda Functions** | `agent-gateway-dev-{authz,tokensvc,gateway,web}` (`arm64`, `512 MiB`, `28s` timeout) |
| **Public Console (`ConsoleURL`)** | `https://0b7565mq7j.execute-api.eu-west-3.amazonaws.com` |
| **Public Gateway (`GatewayURL`)** | `https://p2ye0fbw36.execute-api.eu-west-3.amazonaws.com` |
| **Internal IAM APIs** | `AuthzAPI` (`l2setzbxx0`), `TokensvcAPI` (`b7xncv7c9k`), `GatewayInternalAPI` (`0k8h6g0r7k`) |
| **Cognito User Pool & Domain** | `eu-west-3_8YUGYY8ao` (`https://agw-weather-857710215813.auth.eu-west-3.amazoncognito.com`) |

---

## 2. How the Stack Was Deployed (`scripts/deploy-aws-weather-demo.sh`)

In the `agent-gateway` source repository (`aws` branch), the deployment is automated by `scripts/deploy-aws-weather-demo.sh`:

1. **Prerequisite IAM Access Stack (`agent-gateway-access-dev`)**:
   Deployed once by an account administrator from `deploy/aws/deployment-access.template.json` to attach `DeploymentAccessPolicy` to `AgentGatewayDev` and create the `WorkloadBoundary` managed policy.
2. **Automated 6-Step Deployment Script**:
   ```sh
   bash scripts/deploy-aws-weather-demo.sh \
  --release-manifest dist/aws-lambda/images/release.json \
     --domain-prefix agw-weather-857710215813 \
     --admin-emails stevef1uk@gmail.com \
     --workload-boundary-arn arn:aws:iam::857710215813:policy/agent-gateway-access-dev-WorkloadBoundary-cUd8zZCXC0P0 \
     --profile agent-gateway-dev
   ```
   This script:
   - Ensures `agent-gateway-artifacts-dev` exists and retrieves `ArtifactBucket`.
   - Uploads `keys/customer_private.pem` (`activation/customer.key`) and `keys/aws-evaluation/{authz,tokensvc,gateway,web}.token` with SSE-S3 encryption and records their exact S3 `VersionId`s.
   - Creates the four regional ECR repositories (`agent-gateway-dev/{authz,tokensvc,gateway,web}`) with `AES256` encryption and `ScanOnPush=true`, imports the encrypted ARM64 `_l` images, and verifies their SHA-256 digests.
   - Generates `dist/aws-lambda/plan/parameters.json` via `scripts/prepare-aws-image-deployment.py` with `EnableWeatherDemo=true` and `UpstreamURL=https://api.open-meteo.com`.
   - Creates and executes a CloudFormation change set for `deploy/aws/serverless-images.template.json` (`agent-gateway-dev`) and saves `dist/aws-lambda/plan/teardown-inventory-agent-gateway-dev.json`.
   - Runs live HTTP boundary smoke checks (`200` on public health/discovery, `403` on unsigned internal IAM routes, `403` on spoofed `X-Agent-Gateway-Authorization` envelope headers) and invites the Cognito operator user.

---

## 3. Releasing the repaired console

Commit and push the reviewed source before building. In `agent-gateway`, build
and publish the four encrypted ARM64 images using only the public key directory:

```sh
bash scripts/build-aws-lambda-images.sh /absolute/path/to/public-keys VERSION_TAG --push
```

The build writes `dist/aws-lambda/images/release.json` containing immutable digests,
`source_commit`, and `console_build`. Review that manifest, then pass it explicitly
with `--release-manifest` to the deployment command above. Old release manifests
without matching source/build metadata are rejected instead of silently deploying
an older console. The deployment updates CloudFormation, including model permissions
and environment variables; changing only Lambda code leaves that wiring incomplete.

Before the application update, an administrator must review and update the access
stack from `deploy/aws/deployment-access.template.json`. The workload boundary now
permits Nova Micro through the EU inference profile; the web execution role receives
the corresponding narrow invocation grant. No other service role gets Bedrock access.
The configured model may route to Frankfurt, Stockholm, Ireland or Paris. See the
[AWS Nova Micro model card](https://docs.aws.amazon.com/bedrock/latest/userguide/model-card-amazon-nova-micro.html)
and [inference profile permissions](https://docs.aws.amazon.com/bedrock/latest/userguide/inference-profiles-prereq.html).

The AI status pill says **configured**, not online, until a real generation request
is made. Model invocation failure returns a plan labelled **Local policy rules
(fallback)**. Review the generated resource scope and approval rules before creating
any delegation. Health indicators in the serverless catalogue describe configuration,
not a live upstream probe.

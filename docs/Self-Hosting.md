# Self-Hosting Agent Gateway on AWS


This guide explains what is required to deploy the **Agent Gateway AWS Serverless Edition** into your own AWS account, matching the reference deployment in **Paris (`eu-west-3`)**.

---

## 1. Architecture Overview

When self-hosted in your AWS account, Agent Gateway runs with zero always-on EC2/EKS nodes, NAT gateways, RDS databases, or Redis clusters:

- **3 CloudFormation Stacks**:
  1. `agent-gateway-access-<env>` (`deployment-access.template.json`): Scoped deployment policy and `WorkloadBoundary` IAM permissions boundary.
  2. `agent-gateway-artifacts-<env>` (`artifact-store.template.json`): Private, versioned, SSE-S3 encrypted S3 bucket for activation files.
  3. `agent-gateway-<env>` (`serverless-images.template.json`): Application stack.
- **4 Encrypted ARM64 Lambda Functions (`512 MiB`, `28s` timeout)**:
  - `authz` (Policy Decision Point), `tokensvc` (Token Service), `gateway` (Policy Enforcement Point), and `web` (Admin Console + Amazon Bedrock AI Config Assistant).
- **5 API Gateway v2 HTTP APIs**:
  - 2 public HTTPS APIs (`WebAPI` and allowlisted `GatewayAPI`) + 3 internal `AWS_IAM` HTTPS APIs (`AuthzAPI`, `TokensvcAPI`, `GatewayInternalAPI`).
- **2 DynamoDB On-Demand Tables (`DomainState`, `SecurityState`)** with Point-in-Time Recovery (PITR) and TTL.
- **Amazon Cognito User Pool & PKCE Client** for administrator-invited operator sign-in.
- **AWS Secrets Manager** for generated JWT signing and internal admin secrets.

See [Architecture.md](Architecture.md) for the full component diagram and request flow.

---

## 2. Prerequisites for Self-Hosting

1. **AWS Account & Region**: Target region (e.g., `eu-west-3` Paris) with billing alerts configured (see [Pricing.md](Pricing.md)).
2. **Encrypted ARM64 Lambda Images (`_l` lane)**:
   - `stevef1uk/agent-gateway-{authz,tokensvc,gateway,web}_l` (see [published release digests](releases/0.1.0-aws-c506506.md)), imported into private ECR repositories in your target region.
3. **Customer Activation Material**:
   - Your customer decryption key (`activation/customer.key`) and four vendor-signed service licences (`activation/{authz,tokensvc,gateway,web}.token`) uploaded to your private versioned S3 artifact bucket.
   - Only S3 object keys and `VersionId`s are passed to CloudFormation; secret contents are never placed in template parameters or environment variables.
4. **Cognito Domain Prefix & Operator Email**:
   - A globally unique Cognito Hosted UI domain prefix and your administrator email address for `AdminEmails`.

---

## 3. Deployment Sequence

In an authorized checkout with the release templates and scripts:

1. **Apply the IAM Access & Boundary Stack (`agent-gateway-access-dev`)** as an account administrator and note the `WorkloadBoundaryArn` output.
2. **Run the Automated Deployment Script (`scripts/deploy-aws-weather-demo.sh`)**:
   ```sh
   bash scripts/deploy-aws-weather-demo.sh \
  --release-manifest dist/aws-lambda/images/release.json \
     --domain-prefix <your-unique-cognito-prefix> \
     --admin-emails <your-operator-email> \
     --workload-boundary-arn <WorkloadBoundaryArn>
   ```
3. **Sign In & Verify**:
   - Open `ConsoleURL`, sign in via Cognito, and test `/v1/forecast` (`200 OK`), `/v1/elevation` (`202 Held` -> Approve -> `200 OK`), and revocation (`403 Forbidden`) using either the Console's **Interactive Endpoint Tester** or `bash demo/run-aws-weather-demo.sh`.
4. **Cleanup / Teardown**:
   - Use [Teardown.md](Teardown.md) (`scripts/teardown-aws-deployment.py`) when finished to remove the stacks and choose whether to retain or permanently purge DynamoDB tables, Cognito users, Secrets Manager secrets, CloudWatch logs, and S3 versions.

## Additional AWS demos and optional proxy

See [AWS demos and proxy prerequisites](AWS-Demos.md). API/MCP Lambda demos do not require the proxy VM; forward-proxy clients require the VM and an open SSM tunnel. Backend/OAuth dependencies are separate. The [source Make workflow](../../agent-gateway/docs/aws/make-workflow.md) describes build/deploy/cleanup.

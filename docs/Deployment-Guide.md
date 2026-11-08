# Deploy Agent Gateway to your AWS account

This guide uses only the public **agent-gateway-runtime** repository, branch **aws**. You deploy prebuilt images; you do not need the private source repository, Go, public/private vendor signing keys, or permission to publish Docker Hub images.

**If someone has already deployed your console:** skip to [sign-in and demos](#8-open-your-console-and-sign-in). Ask the operator for ConsoleURL, an invitation and the selected demo's GatewayURL. You do not need deployment credentials merely to run an agent client.

**If you are deploying into your own account:** follow the steps in order. Only the administrator access step and explicit deploy/proxy/cleanup commands change AWS resources. No OpenClaw or other extra application VM is created.

## 1. Install workstation tools and get this branch

You need Git, Make, Python 3, Node.js, curl, AWS CLI v2 and Docker (including Buildx). Docker must be running and able to pull/tag/push ARM64 images. You do **not** build application images; Docker transfers the vendor images into your account's ECR. cfn-lint/cfn-guard are optional extra local template validators.

```bash
git clone --branch aws https://github.com/stevef1uk/agent-gateway-runtime.git
cd agent-gateway-runtime
make check
```

If already cloned, use your existing checkout on `aws` and pull the latest changes, preserving any local work. **Expected:** syntax checks and offline tests pass. This does not contact AWS or prove an AWS deployment exists.

The supported scripted region is **Paris (`eu-west-3`)**. Keep that value for this workflow. Templates and bounded access policies are not a generic multi-region installer.

## 2. Set up the deployment identity

An administrator creates the **`AgentGatewayDev` IAM role** and allows your existing AWS identity to assume it. In IAM → Roles → Create role, configure the trust for your approved identity, name the role `AgentGatewayDev`, and leave application permissions for the access-stack template in step 5. For an existing role, check its **Trust relationships** instead. Follow [AWS role/profile setup](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-role.html) for your identity type and any MFA requirement.

These names refer to different things:

| Name | Meaning |
|---|---|
| IAM user `agent-gateway-dev` | Your source identity; its permissions do not carry into an assumed-role session |
| CLI profile `agent-gateway-user` | Credentials for that user |
| IAM role `AgentGatewayDev` | Receives the deployment policies from step 5 |
| CLI profile `agent-gateway-dev` | Uses the source profile to assume that role |

For this IAM-user example, add the following to `~/.aws/config`, replacing `YOUR_ACCOUNT` with your 12-digit account ID. Keep credentials in the existing source profile, not this repository.

```ini
[profile agent-gateway-dev]
role_arn = arn:aws:iam::YOUR_ACCOUNT:role/AgentGatewayDev
source_profile = agent-gateway-user
region = eu-west-3
```

Verify which identity each profile actually uses:

```bash
aws sts get-caller-identity --profile agent-gateway-user
aws sts get-caller-identity --profile agent-gateway-dev
```

**Expected:** the first ARN ends in `user/agent-gateway-dev`; the second contains `assumed-role/AgentGatewayDev/`. Other source identities, such as IAM Identity Center, have different source ARNs. An `AssumeRole` denial requires administrator review of trust, assumption permissions and MFA.

Continue with steps 3–4 before deploying anything. Signing into the administrator Console does not change CLI credentials.

## 3. Obtain the current release and activation files

The `releases/current.json` vendor manifest is included in this repository's `aws` branch. If you cloned on `aws`, it is already present:

```bash
ls releases/current.json
```

**Expected:** the file exists with schema version 2.

If you need to update the manifest (e.g. for a new release), obtain a schema-2 manifest from the vendor and save it to `releases/current.json`. The manifest must target `linux/arm64` and include all four encrypted product image digests plus the Emotion wrapper.

```bash
make aws-release-check
```

**Expected:** `Valid AWS release: ... (four encrypted product images + Emotion wrapper)`. If the manifest is stale or invalid, obtain a current release from the vendor.

Keep activation files out of Git. The script uploads the customer key and signed service licences to your private versioned S3 bucket; only object identifiers/versions go into CloudFormation parameters. Never supply a vendor signing private key. These product licences are separate from Emotion's native licence: an optional purchased Emotion token is not required to deploy or test gateway approval/error forwarding.

## 4. Create your local configuration

```bash
cp aws-config.example.mk aws-config.mk
```

Edit **aws-config.mk**, not the example. It is ignored by Git. Fill these values:

| Setting | Where its value comes from |
|---|---|
| `AWS_PROFILE` | Named non-root profile from step 2 |
| `AWS_ACCOUNT` | Account number printed by STS in step 2 |
| `AWS_DEPLOYMENT_ROLE_NAME` | Existing role assumed by that profile; ask your administrator if unsure |
| `AWS_ADMIN_PROFILE` | Separate approved administrator profile for step 5 |
| `AWS_REGION` | Keep `eu-west-3` |
| `AWS_STACK`, `AWS_ARTIFACT_STACK`, `AWS_ACCESS_STACK` | Keep example names for your first isolated deployment, or agree consistent names with the administrator |
| `RELEASE_MANIFEST` | Path where you saved the current vendor manifest |
| `CUSTOMER_KEY_FILE` | Actual local path to the compatible customer private key |
| `LICENCE_DIR` | Actual directory containing the four named service `.token` files |
| `DOMAIN_PREFIX` | Choose a unique lowercase Cognito prefix, e.g. your organization's name plus a random suffix; this is a name you choose, not an API ID |
| `ADMIN_EMAILS` | Your real reachable operator email; multiple emails comma-separated without spaces |
| `WORKLOAD_BOUNDARY_ARN` | Leave empty until step 5; copy the administrator stack output exactly |

Use paths without spaces in this Make configuration. Keep credentials in the AWS credential provider/profile, not this file. `DEMO_DEPLOYMENT_ROLE_ARN` is derived automatically from your account and application stack; no ARN guessing is needed.

```bash
make aws-identity
make aws-preflight
```

**Expected:** the intended account/role and passing local manifest/config/file checks. Preflight checks file presence and release identifiers; it does not validate licence signatures or create AWS resources. Fix any missing inputs before continuing.

## 5. Administrator: create or update deployment access

Review `deploy/aws/deployment-access.template.json`. It attaches scoped deployment policies to the existing `AgentGatewayDev` role and creates the workload boundary and demo-deployment role. It creates no application compute or databases. **Attach deployment permissions to the role, not just the source IAM user.**

Choose one method:

- **Console:** In CloudFormation, Paris (`eu-west-3`), create `agent-gateway-access-dev` by uploading the template. If that stack already exists, choose **Update stack → Create a change set → Replace existing template → Upload a template file** instead. Keep `DeploymentRole=AgentGatewayDev`, `ApplicationStack=agent-gateway-dev`, and `ArtifactStack=agent-gateway-artifacts-dev` for the default setup. Review the changes, acknowledge named IAM resources, and execute the change set.
- **CLI:** Use a separately authenticated administrator profile. After configuring step 4, run:

```bash
make aws-access-deploy AWS_ADMIN_PROFILE=YOUR_ADMIN_PROFILE
make aws-access-outputs AWS_ADMIN_PROFILE=YOUR_ADMIN_PROFILE
```

The CLI command executes the change set and waits. **Expected:** `CREATE_COMPLETE` or `UPDATE_COMPLETE`. For Console setup, read the same values from the stack's **Outputs** tab.

Copy **WorkloadBoundaryArn** into `WORKLOAD_BOUNDARY_ARN` in `aws-config.mk`. Check **DemoDeploymentRoleArn** matches `arn:aws:iam::YOUR_ACCOUNT:role/YOUR_APPLICATION_STACK-demo-deployer`; Make derives this identifier automatically. Keep `AWS_PROFILE=agent-gateway-dev` for application deployment. Do not set `AWS_ADMIN_PROFILE` to the restricted deployment role.

### Existing stack or AccessDenied?

Pulling a newer template does **not** update live IAM policies. If deployment still reports `AccessDenied` for `cloudformation:DescribeEvents`, update the access stack as an administrator:

1. Pull the latest `aws` branch in this repository (`git pull` with a clean checkout).
2. In the administrator AWS Console, open **CloudFormation → Europe (Paris)**.
3. Select **`agent-gateway-access-dev`**, not the application stack `agent-gateway-dev`.
4. Choose **Update stack → Create a change set → Replace existing template → Upload a template file**.
5. Upload **`deploy/aws/deployment-access.template.json`** from this checkout.
6. Keep existing parameters; verify **`DeploymentRole=AgentGatewayDev`**. Continue, acknowledge named IAM resources, and create the change set.
7. Review it and choose **Execute change set**. Wait for the **access stack** to show **`UPDATE_COMPLETE`**; merely creating a change set does not apply permissions.
8. Run the checks below, then retry **`make aws-deploy`**.

If checks still return `AccessDenied`, inspect IAM → Roles → **AgentGatewayDev → Permissions** as administrator: the access stack's `DeploymentAccess` managed policy must be attached and its default version must contain the missing action. Confirm the access stack's **Events** show a successful update. Changing only the IAM user's permissions or recreating the application does not update the assumed role.

These copyable checks use the default profile and stack names from this guide. If you chose different names, change them below. The policy ARN and version are discovered automatically:

```bash
(
  set -e
  aws sts get-caller-identity --profile agent-gateway-dev
  agw_boundary=$(aws cloudformation describe-stacks \
    --profile agent-gateway-dev --region eu-west-3 \
    --stack-name agent-gateway-access-dev \
    --query 'Stacks[0].Outputs[?OutputKey==`WorkloadBoundaryArn`].OutputValue | [0]' \
    --output text)
  case "$agw_boundary" in arn:aws:iam::*:policy/*) ;; *) echo 'Missing workload boundary output'; exit 1 ;; esac
  agw_policy_version=$(aws iam get-policy --profile agent-gateway-dev \
    --policy-arn "$agw_boundary" --query 'Policy.DefaultVersionId' --output text)
  aws iam get-policy-version --profile agent-gateway-dev \
    --policy-arn "$agw_boundary" --version-id "$agw_policy_version"
  aws cloudformation describe-events --profile agent-gateway-dev \
    --region eu-west-3 --stack-name agent-gateway-dev --filters FailedEvents=true
)
```

The event check applies after an application stack/change set exists. A missing-stack error differs from `AccessDenied`. These checks read configuration only; they do not grant permissions.

If early validation reports `AWS::EarlyValidation::ResourceExistenceCheck`, open the failed change set's **Deployment validations** tab in the administrator Console if CLI event access is denied. `logs:DescribeIndexPolicies` is a required read-only discovery permission; the access template grants it with regional scope because AWS does not support log-group resource scoping for that action.

Deleting a stack does not delete resources marked `Retain`. Existing `agent-gateway-dev-domain` / `agent-gateway-dev-security` tables and named log groups will conflict with a fresh create. Preserve their data: import the retained resources into the replacement stack before deploying the rest, or deliberately choose a separate deployment name and access configuration. Do not delete tables merely to clear validation errors.

If early validation reports `AWS::EarlyValidation::ResourceExistenceCheck`, inspect these events before retrying. The current template grants `cloudformation:DescribeEvents` and read-only `iam:GetPolicy` / `iam:GetPolicyVersion` on the exact workload boundary. An administrator must apply it to make those grants live. Do not give the deployer permission to edit its own policies or attach AdministratorAccess. Remove the access stack only after workload cleanup.

## 6. Deploy the application (creates billable AWS resources)

Keep Docker running, then:

```bash
make aws-deploy
```

The script checks the selected account/profile, current manifest, and live IAM prerequisites before any deployment writes. Missing boundary reads, log-index discovery or event diagnostics stop immediately with the administrator recovery step. It then:

1. Creates/reuses private versioned activation storage.
2. Uploads/pins customer activation material.
3. Pulls the four encrypted `_l` images and prebuilt Emotion wrapper from Docker Hub into private ECR, checking every digest.
4. Generates CloudFormation parameters from your configuration and discovered S3 versions, including deploy-time JWT/operator secrets passed as `NoEcho` values.
5. Creates/updates the Lambda application, HTTP APIs, Cognito and DynamoDB through a change set.
6. Saves a teardown inventory, checks public/internal HTTP boundaries and sends the first configured operator's Cognito invitation if needed.

JWT and operator tokens are generated once and stored in `dist/aws-lambda/plan/secrets.json` (mode 0600, git-ignored), then passed as `NoEcho` parameters. Keep that file to preserve the same tokens across redeploys; deleting it rotates both secrets and invalidates existing tokens and admin sessions. AWS Secrets Manager is the recommended production alternative for rotation and audit, but this demo avoids its per-secret monthly cost.

The parent uses Lambda and managed services; it does not create the optional proxy VM or OpenClaw hosts. [Architecture](Architecture.md) explains single-region availability and limits. Bedrock configuration/permissions for the AI Wizard remain enabled; successful model invocation also depends on account/model availability.

**Expected:** the script prints **Deployment Complete**, actual **ConsoleURL**, baseline **GatewayURL**, pool ID and operator email. It saves endpoint identifiers to `dist/aws-lambda/plan/deployment-outputs.env` and cleanup inventory under `dist/aws-lambda/teardown/`. Keep those local files for later cleanup/recovery.

If deployment fails, inspect the named stack's CloudFormation **Events** for the first underlying resource failure. Resolve that error before testing; a printed plan or created ECR repository alone does not mean deployment succeeded. Keep the inventory and rerun with the same configuration after correction.

## 7. Retrieve URLs without editing placeholders

```bash
make aws-outputs
```

This read-only command prints parent stack outputs. Open the **ConsoleURL** value. Do not type an example API ID, append `/api` to it, or confuse it with the gateway.

## 8. Open your console and sign in

Use your emailed Cognito invitation and configured email address. Choose Cognito sign-in and complete the temporary-password/reset flow as prompted. If no invitation arrives, check spam and ask the deployment owner to inspect/resend it for the correct pool/email. Do not use a local-demo password or AWS access key as a login.

For an existing hosted deployment, get ConsoleURL and the invitation from its owner; skip all provisioning steps above.

## 9. Create the Users demo and its delegation

In the AI Wizard select **Users**, review the public JSONPlaceholder upstream, permit read access to `/api-users/users*`, and choose **Deploy Demo & Create Delegation**. Wait for successful demo deployment. Mint/copy an agent token for that delegation using the console's token controls. Keep it private.

From this runtime checkout:

```bash
make -s aws-demo-url DEMO=users
export GATEWAY_URL="$(make -s aws-demo-url DEMO=users)"
unset AGENT_TOKEN
make aws-demo DEMO=users
```

The first command prints the complete child URL; the export uses that exact value. The client privately prompts for the **Users agent token**. **Expected:** `PASS users access: HTTP 200`.

The child is `AWS_STACK-demo-api-users`; a missing-stack error means Users has not been deployed under your selected account/region/name. AccessDenied/expired-session errors need profile inspection/sign-in fixes. You can also copy the child's **GatewayURL** from CloudFormation **Outputs**. Without AWS inspection access, ask the operator for that complete URL and enter it:

```bash
printf 'Paste the complete Users GatewayURL: '
read -r GATEWAY_URL
export GATEWAY_URL
unset AGENT_TOKEN
make aws-demo DEMO=users
```

A console URL, AWS credentials, Cognito login token and agent token serve different purposes. Never send an agent token directly to the public upstream provider. Each demo has its own gateway URL and matching delegation.

## 10. Test Emotion's approval sequence

Use the Wizard to deploy **Emotion** and create a delegation allowing `emotion_detection` while requiring approval for `emotion_detection_detailed`. Mint its agent token, then switch endpoints:

```bash
export GATEWAY_URL="$(make -s aws-demo-url DEMO=emotion)"
unset AGENT_TOKEN
make aws-demo DEMO=emotion PHASE=access
make aws-demo DEMO=emotion PHASE=held
```

Enter the **same Emotion delegation token** at each prompt. The held command returns HTTP 202 and an approval ID. Approve **that exact request** in the console's pending approvals, then:

```bash
make aws-demo DEMO=emotion PHASE=approved
make aws-demo DEMO=emotion PHASE=held
```

**Expected:** the approved retry returns HTTP 200 and the next call is held again because approval was single-use. The published Emotion container enforces its licence; a native licence error inside its MCP response is valid for testing the gateway, but does not establish successful inference.

Revoke the delegation in the console before the token expires, then:

```bash
make aws-demo DEMO=emotion PHASE=revoked
```

**Expected:** HTTP 403. [All demos](AWS-Demos.md) explains weather/geocoding/refunds, optional-token delivery and baseline weather routes.

## 11. Optional infrastructure is a separate decision

No proxy is required for these five Lambda API/MCP presets. If you deliberately want a forward-proxy/CONNECT demo, read [Proxy VM](Proxy-VM.md) first: it has explicit create/connect/delete commands and ongoing EC2/storage/IPv4 costs. Do not run create merely to test Users or Emotion.

OpenClaw/OpenShell and custom stateful backends are **not** provisioned by these scripts. Follow [customer-managed hosts](Customer-Managed-Demos.md) if you later choose to supply them yourself.

## 12. Finish and clean up

For a hosted/shared deployment, revoke your test delegations, run `unset AGENT_TOKEN`, sign out and leave resource cleanup to the owner.

For your own deployment, use [Teardown](Teardown.md). It distinguishes demo deletion, parent removal with retained data, permanent purge, ECR removal and final administrator access cleanup. Closing the console or terminal does not remove billable resources.

### Demo signing secrets

The encrypted-image web function receives the same JWT signing value and operator
value as the parent gateway. The wizard supplies these to child stacks as separate
`NoEcho` parameters. They never enter `DemoConfiguration` outputs or child template
bodies. The source CLI reads `dist/aws-lambda/plan/secrets.json` for demo deployment
(`--secrets-file` overrides the path); retain that private local file for updates.
A rebuilt web image is required for this parameter-based provisioning path.

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

## 2. Attach IAM policies & deploy (3 steps)

### You have root access — follow these 3 steps:

**Step 1: Attach policies to AgentGatewayDev role**

Go to IAM → Roles → AgentGatewayDev (account 111111111111) → Add permissions → Attach policies directly → Paste this inline policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "cloudformation:CreateChangeSet",
        "cloudformation:DescribeStacks",
        "cloudformation:CreateStack",
        "cloudformation:UpdateStack",
        "cloudformation:ValidateTemplate"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:PutObject",
        "s3:GetBucketLocation",
        "s3:DeleteBucket"
      ],
      "Resource": [
        "arn:aws:s3:::agent-gateway-artifacts-dev",
        "arn:aws:s3:::agent-gateway-artifacts-dev/*"
      ]
    }
  ]
}
```

Click **Add permissions**.

**Step 2: Run the access deployment**

```bash
make aws-access-deploy
```

Wait for the CloudFormation stack to reach `CREATE_COMPLETE` status (you may need to click **Execute** on the change set in the Console if it stays in `REVIEW_IN_PROGRESS`).

**Step 3: Deploy the application**

```bash
make aws-access-outputs    # Copy WorkloadBoundaryArn value into aws-config.mk
make aws-deploy            # Deploys the application
```

**Why this works:** The inline policy gives `AgentGatewayDev` the CloudFormation and S3 permissions needed for the access boundary workflow.

**After running `make aws-access-outputs`:**
- Copy the `WorkloadBoundaryArn` value from the output
- Add it to `aws-config.mk`: `WORKLOAD_BOUNDARY_ARN = arn:aws:iam::...`
- Then run `make aws-deploy` to deploy the application

**Why this works:** The inline policy gives `AgentGatewayDev` the CloudFormation and S3 permissions needed for the access boundary workflow. After Step 3, you can run `make aws-deploy` to deploy the application.

**That's it — 3 steps and you're done.** No two-profile complexity, no admin profile setup, no root login required beyond the Console.
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

## 5. Administrator: apply bounded deployment access

This step creates IAM policies, a workload permissions boundary and a fixed CloudFormation demo-deployment role. It does not create application compute/database resources. The administrator should review `deploy/aws/deployment-access.template.json` and ensure the configured deployer role already exists.

```bash
make aws-access-deploy
make aws-access-outputs
```

The first command uses only the explicit `AWS_ADMIN_PROFILE`, checks its account matches `AWS_ACCOUNT`, acknowledges the template's named IAM resources, and waits for completion. **Expected:** successful stack creation/update, followed by outputs including **WorkloadBoundaryArn** and **DemoDeploymentRoleArn**.

Copy the complete **WorkloadBoundaryArn** value into `WORKLOAD_BOUNDARY_ARN` in `aws-config.mk`. Verify DemoDeploymentRoleArn matches `arn:aws:iam::YOUR_ACCOUNT:role/YOUR_APPLICATION_STACK-demo-deployer`; Make derives that value for deployment. The ARN identifiers are not secrets. Return to the non-root application profile for step 6.

If IAM access is denied, ask the administrator to review the missing action/trust; do not attach AdministratorAccess to the application role. Removing the access stack while workload roles remain can make them unusable, so access cleanup is last.

## 6. Deploy the application (creates billable AWS resources)

Keep Docker running, then:

```bash
make aws-deploy
```

The script checks the selected account/profile and current manifest, then:

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

For an existing access stack, an administrator must **update** it from the current
`deploy/aws/deployment-access.template.json`. The update adds CloudFormation event
and change-set inspection and read-only `iam:GetPolicy` / `iam:GetPolicyVersion`
access to the exact workload boundary. Recreating the application does not refresh
the deployment role's policies.

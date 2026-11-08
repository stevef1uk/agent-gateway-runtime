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

## 2. Arrange AWS profiles with your administrator

Your AWS administrator supplies an existing non-root role and a named CLI profile that assumes it. The default profile name is `agent-gateway-dev`, but that name is local configuration, not an AWS account automatically created by this project.

You need two separate responsibilities (one person may perform both):

| Responsibility | Profile/configuration | Used for |
|---|---|---|
| Application deployer | `AWS_PROFILE` and its existing IAM role name, `AWS_DEPLOYMENT_ROLE_NAME` | Application/ECR/S3 deployment after bounded access is applied |
| Account administrator | Explicit `AWS_ADMIN_PROFILE` | Reviewing/applying IAM access and boundary template, then removing it after cleanup |

Ask the administrator to configure the deployer role's trust/assumption according to your organization's sign-in method. The access template attaches policies to that **existing role**; it does not create the human identity or fix profile trust. The deployer cannot grant itself these permissions. Do not use root as the application deployment profile.

Run the read-only identity check once the profile is configured:

```bash
aws sts get-caller-identity --profile agent-gateway-dev
```

Use your actual profile name if different. **Expected:** your intended 12-digit account and a non-root assumed-role ARN. Record the account number and role name. If authentication fails, resolve it with your administrator before deployment.

## 3. Obtain the current release and activation files

Obtain these from the vendor/release operator:

| Input | What to do with it |
|---|---|
| Current AWS release manifest (`current.json` or versioned JSON) | Save as `releases/current.json`, or set `RELEASE_MANIFEST` to its actual path |
| Customer decryption private key compatible with those images | Save privately; set `CUSTOMER_KEY_FILE` to its actual path |
| Four valid vendor-signed service licences | Put `authz.token`, `tokensvc.token`, `gateway.token`, `web.token` in a private directory; set `LICENCE_DIR` |

The current manifest must include all four encrypted Docker Hub `_l` image digests and the prebuilt Emotion Lambda wrapper. The deployment script validates the manifest and copies those immutable images into **your own private Paris ECR**, preserving digests. Customers never compile these binaries. A vendor image release and compatible activation material are required even if the repository is public.

**Release availability:** the repository's older `0.1.0-aws-c506506` manifest predates the complete Wizard workflow and is deliberately rejected. A compatible new manifest must be published/supplied before a first deployment of this updated workflow. Do not invent a download URL, use `latest`, or remove validation to reuse an older release. The vendor builds/publishes the release separately; cloning this branch does not publish it.

```bash
mkdir -p releases
# Save the actual vendor manifest as releases/current.json, then:
make aws-release-check
```

**Expected:** `Valid AWS release: ... (four encrypted product images + Emotion wrapper)`. Missing/old-manifest errors mean you need the current release, not access to application source.

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
4. Generates CloudFormation parameters from your configuration and discovered S3 versions.
5. Creates/updates the Lambda application, HTTP APIs, Cognito, DynamoDB and Secrets Manager through a change set.
6. Saves a teardown inventory, checks public/internal HTTP boundaries and sends the first configured operator's Cognito invitation if needed.

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

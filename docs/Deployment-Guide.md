# Deploy Agent Gateway to your AWS account

This guide uses only the public **agent-gateway-runtime** repository, branch **aws**. You deploy prebuilt images; you do not need the private source repository, Go, vendor signing keys, or permission to publish Docker Hub images.

**Which path are you on?**

| Situation | What to do |
|---|---|
| Someone has already deployed your console | Skip to [step 8](#8-open-your-console-and-sign-in). Ask the operator for the **ConsoleURL**, an invitation and the **GatewayURL** of the demo you want to run. You do not need AWS deployment credentials to run an agent client. |
| You are deploying into your own account | Follow steps 1–12 in order. |

Only step 2B (creating the administrator), step 5 (access stack), step 6 (deploy), the optional proxy VM and the cleanup commands change AWS resources. No OpenClaw or other extra application VM is created.

## Contents

1. [Install workstation tools and get this branch](#1-install-workstation-tools-and-get-this-branch)
2. [Set up your AWS identities](#2-set-up-your-aws-identities)
3. [Obtain the release and activation files](#3-obtain-the-current-release-and-activation-files)
4. [Create your local configuration](#4-create-your-local-configuration)
5. [Administrator: create deployment access](#5-administrator-create-or-update-deployment-access)
6. [Deploy the application](#6-deploy-the-application-creates-billable-aws-resources)
7. [Retrieve URLs](#7-retrieve-urls-without-editing-placeholders)
8. [Open your console and sign in](#8-open-your-console-and-sign-in)
9. [Create the Users demo](#9-create-the-users-demo-and-its-delegation)
10. [Test Emotion's approval sequence](#10-test-emotions-approval-sequence)
11. [Optional infrastructure](#11-optional-infrastructure-is-a-separate-decision)
12. [Finish and clean up](#12-finish-and-clean-up)
13. [Troubleshooting](#13-troubleshooting)

## The big picture

Deployment uses **two** AWS identities with very different powers. Most failures in this process come from mixing them up.

| Identity | CLI profile | Used for |
|---|---|---|
| **Deployer** (restricted) | `agent-gateway-dev`, which assumes the IAM role `AgentGatewayDev` | Everyday deployment: `make aws-deploy`, outputs, demos, teardown of the workload |
| **Administrator** (privileged) | `agent-gateway-admin` | Rarely: creating or updating the access stack (step 5) and final access cleanup |

The deployer role cannot grant itself permissions; that is deliberate. The access stack, created once by an administrator, is what gives the role its scoped deployment permissions. So **an administrator identity must exist before you can deploy.**

Rough effort: about 20 minutes for identities and configuration, then the deployment itself, which pulls images and creates the stack and can take considerably longer on a slow connection.

## 1. Install workstation tools and get this branch

You need:

- Git, Make, Python 3, Node.js, curl and OpenSSL
- **AWS CLI v2**, recent enough to include the `aws login` command (check with `aws --version`)
- Docker, running, with Buildx, able to pull, tag and push ARM64 images

You do **not** build application images; Docker transfers the vendor images into your account's ECR. cfn-lint and cfn-guard are optional extra template validators.

```bash
git clone --branch aws https://github.com/stevef1uk/agent-gateway-runtime.git
cd agent-gateway-runtime
make check
```

If you already have a checkout, switch to the `aws` branch and pull the latest changes, preserving any local work.

**Expected:** syntax checks and offline tests pass. This does not contact AWS and does not prove a deployment exists.

The supported scripted region is **Paris (`eu-west-3`)**. Keep that value. The templates and bounded access policies are not a generic multi-region installer.

## 2. Set up your AWS identities

This step has two parts: **2A** creates the restricted deployer, and **2B** creates the administrator. Do both before continuing.

### 2A. The deployer: IAM user, role and CLI profiles

An existing administrator (or the root user, for a brand-new account) does the following in the console:

1. **Create an IAM user** `agent-gateway-dev`. This is your source identity. Its own permissions do not carry into an assumed-role session.
2. **Create the IAM role** `AgentGatewayDev` (IAM → Roles → Create role → Custom trust policy). Leave application permissions empty; step 5 attaches them. The trust policy should allow that user to assume the role:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": { "AWS": "arn:aws:iam::YOUR_ACCOUNT:user/agent-gateway-dev" },
       "Action": "sts:AssumeRole"
     }]
   }
   ```

   If your organisation requires MFA, add the matching condition; see [AWS role/profile setup](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-role.html). For an existing role, check its **Trust relationships** tab instead.
3. **Sign the CLI in as the user.** Use `aws login` with an explicit profile name (see the warning below):

   ```bash
   aws login --profile agent-gateway-user
   ```

Replace `YOUR_ACCOUNT` with your 12-digit account ID. Then add the role profile to `~/.aws/config`, keeping credentials in the source profile and never in this repository:

```ini
[profile agent-gateway-dev]
role_arn = arn:aws:iam::YOUR_ACCOUNT:role/AgentGatewayDev
source_profile = agent-gateway-user
region = eu-west-3
```

| Name | Meaning |
|---|---|
| IAM user `agent-gateway-dev` | Source identity |
| CLI profile `agent-gateway-user` | Credentials for that user |
| IAM role `AgentGatewayDev` | Receives the deployment policies in step 5 |
| CLI profile `agent-gateway-dev` | Assumes the role using the source profile |

> **Always pass `--profile` to `aws login`.** Without it the CLI targets the `default` profile. If `default` already holds static access keys, you get *"Profile 'default' is already configured with Access Key credentials"* and nothing is changed.

Verify what each profile resolves to:

```bash
aws sts get-caller-identity --profile agent-gateway-user
aws sts get-caller-identity --profile agent-gateway-dev
```

**Expected:** the first ARN ends in `user/agent-gateway-dev`; the second contains `assumed-role/AgentGatewayDev/`. A `session has expired` error means you need to run `aws login --profile agent-gateway-user` again. An `AssumeRole` denial needs an administrator to review the trust policy and any MFA requirement. Other source identity types, such as IAM Identity Center, show different source ARNs.

### 2B. The administrator: a separate, genuinely privileged profile

Step 5 needs credentials that can create IAM roles and policies and CloudFormation stacks. The deployer identities from 2A are meant to have no such rights (the role only gains scoped permissions from the access stack itself), so use a separate administrator identity. Do not use the root user for CLI work, and do not grant `AdministratorAccess` to `agent-gateway-dev` or the `AgentGatewayDev` role: that would defeat the least-privilege design.

1. **Create the identity (console, one time).** Sign in as root (or an existing admin), open IAM → Users → Create user, name it `agent-gateway-admin`, and attach the `AdministratorAccess` policy. Then sign out of root.
2. **Give the CLI credentials for it.** Choose one method.

   **Method 1: access keys (most reliable).** In the console open IAM → Users → `agent-gateway-admin` → Security credentials → Create access key, choose the **CLI** use case, and then run:

   ```bash
   aws configure --profile agent-gateway-admin
   ```

   Enter the access key ID and secret, and set the region to `eu-west-3`. **Use the profile name `agent-gateway-admin` exactly.** Running `aws configure` against `agent-gateway-dev` writes static keys into `~/.aws/credentials` that override the role settings in `~/.aws/config`, so that profile stops assuming `AgentGatewayDev` and silently runs as the IAM user. Never paste the key or secret into chat, tickets or logs; if you do, delete the key in IAM and create a new one. Delete the access key in IAM once step 5 has finished (see [step 12](#12-finish-and-clean-up)); long-lived admin keys are a liability and you rarely need them.

   **Method 2: IAM Identity Center (no long-lived keys).** If your organisation uses it, run `aws configure sso --profile agent-gateway-admin` followed by `aws sso login --profile agent-gateway-admin`.

   **Method 3: `aws login` (use with care).** `aws login --profile agent-gateway-admin` authenticates whoever the browser is **already signed in as**. If that is `agent-gateway-dev`, the new profile silently becomes a third alias for that restricted user (look for `login_session = ...user/agent-gateway-dev` in its config block). To use this method, sign out of AWS in every browser window, run the command with `--remote`, and open the printed URL in a fresh private window, signing in as the **IAM user** `agent-gateway-admin`.
3. **Verify before you use it.**

   ```bash
   aws sts get-caller-identity --profile agent-gateway-admin
   ```

   **Expected:** the ARN ends in `user/agent-gateway-admin` (or your Identity Center admin role). If it ends in `user/agent-gateway-dev`, the profile is not an administrator: remove its block from `~/.aws/config` and set it up again. Do not continue until this is correct.

`AWS_ADMIN_PROFILE` always takes a **profile name** from `~/.aws/config` or `~/.aws/credentials`. It does not accept an account ID or an email address.

Signing into the administrator Console does not change CLI credentials. The two are independent.

## 3. Obtain the current release and activation files

The `releases/current.json` vendor manifest is included in this repository's `aws` branch. If you cloned on `aws`, it is already present:

```bash
ls releases/current.json
```

**Expected:** the file exists with schema version 2.

To update it for a new release, obtain a schema-2 manifest from the vendor and save it to `releases/current.json`. It must target `linux/arm64` and include all four signed-licence product image digests plus the Emotion wrapper.

```bash
make aws-release-check
```

**Expected:** `Valid AWS release: ... (four signed-licence product images + Emotion wrapper)`. If the manifest is stale or invalid, obtain a current release from the vendor.

You need a genuine **vendor public key** and **four signed service licences** from the vendor. The customer private key is used only by the optional Emotion backend:

- Vendor public key: `keys/local-activation/vendor_public.pem`
- Emotion customer key: `keys/local-activation/customer_private.pem`
- Licences: four `.token` files under `keys/local-activation/licences/`

These are the configuration defaults. The directory is Git-ignored; keep activation files out of Git. Tracked key/token examples in the repository are placeholders and cannot start the licensed services, so leave them unchanged.

The script uploads signed licences and the customer key needed by the optional Emotion backend to your private, versioned S3 bucket; only object identifiers and versions go into CloudFormation parameters. Never supply a vendor signing private key. These gateway licences are separate from Emotion's native licence: a purchased Emotion token is optional and is not needed to deploy or test approval and error forwarding.

## 4. Create your local configuration

```bash
cp aws-config.example.mk aws-config.mk
```

Edit **aws-config.mk**, not the example. It is ignored by Git. Fill in:

| Setting | Where its value comes from |
|---|---|
| `AWS_PROFILE` | `agent-gateway-dev` (the non-root deployer profile from step 2A) |
| `AWS_ACCOUNT` | The 12-digit account number printed by STS in step 2A |
| `AWS_DEPLOYMENT_ROLE_NAME` | `AgentGatewayDev`, the role that profile assumes |
| `AWS_ADMIN_PROFILE` | The administrator **profile name** from step 2B (for example `agent-gateway-admin`) |
| `AWS_REGION` | Keep `eu-west-3` |
| `AWS_STACK`, `AWS_ARTIFACT_STACK`, `AWS_ACCESS_STACK` | Keep the example names for a first isolated deployment, or agree consistent names with your administrator |
| `RELEASE_MANIFEST` | Path to the vendor manifest from step 3 |
| `CUSTOMER_KEY_FILE` | Actual local path to the customer private key |
| `VENDOR_PUBLIC_KEY_FILE` | Actual local path to the public key used to verify vendor licence signatures |
| `LICENCE_DIR` | Actual directory containing the four service `.token` files |
| `DOMAIN_PREFIX` | A unique lowercase Cognito prefix you choose, such as your organisation name plus a random suffix. It is not an API ID |
| `ADMIN_EMAILS` | Your real, reachable operator email; separate several with commas and no spaces |
| `WORKLOAD_BOUNDARY_ARN` | Leave empty when `AWS_ADMIN_PROFILE` is configured; the deployment reads and account-checks the stack output automatically. Otherwise copy the access stack's **`WorkloadBoundaryArn`** output exactly. It is a **policy** ARN (`arn:aws:iam::ACCOUNT:policy/...-WorkloadBoundary-...`), not the `demo-deployer` **role** ARN from the neighbouring output, and it must have no trailing space |

Use paths without spaces. Keep credentials in the AWS credential provider, never in this file. `DEMO_DEPLOYMENT_ROLE_ARN` is derived automatically from your account and application stack.

```bash
make aws-identity
make aws-preflight
```

**Expected:** the intended account and the **assumed role** (`assumed-role/AgentGatewayDev/...`), plus passing manifest, configuration and activation checks. If `make aws-identity` shows `user/agent-gateway-dev` instead, a static-key entry for `[agent-gateway-dev]` in `~/.aws/credentials` is overriding the role profile; delete that section and run it again, because deploying as the user bypasses the scoped role. Preflight validates the Emotion customer-key format and verifies each service licence's RSA-PSS signature and expiry against the vendor public key. It checks release image references but does not decrypt or launch the service images. It creates no AWS resources; fix any missing or mismatched inputs before continuing.

## 5. Administrator: create or update deployment access

Review `deploy/aws/deployment-access.template.json`. It attaches scoped deployment policies to the existing `AgentGatewayDev` role and creates the workload boundary and the demo-deployment role. It creates no application compute or databases. **Permissions are attached to the role, not just the source IAM user.**

Choose one method.

**CLI (recommended once step 2B is done):**

```bash
make aws-access-deploy AWS_ADMIN_PROFILE=agent-gateway-admin
make aws-access-outputs AWS_ADMIN_PROFILE=agent-gateway-admin
```

The first command executes a change set and waits. Before the application exists, it uses nonfunctional placeholder values for optional proxy permissions; after deploying the application, run it again to synchronize those permissions from the parent's `DemoConfiguration` output. **Expected:** `CREATE_COMPLETE` or `UPDATE_COMPLETE`.

**Console:** in CloudFormation, Paris (`eu-west-3`), create the stack `agent-gateway-access-dev` by uploading the template. If it already exists, choose **Update stack → Create a change set → Replace existing template → Upload a template file** instead. Keep `DeploymentRole=AgentGatewayDev`, `ApplicationStack=agent-gateway-dev` and `ArtifactStack=agent-gateway-artifacts-dev`. Review the changes, acknowledge named IAM resources, and execute the change set. Then read the outputs from the stack's **Outputs** tab and put `WorkloadBoundaryArn` into `WORKLOAD_BOUNDARY_ARN`.

With `AWS_ADMIN_PROFILE` set, Make reads **WorkloadBoundaryArn** automatically and verifies that the administrator profile targets `AWS_ACCOUNT`. Check that **DemoDeploymentRoleArn** matches `arn:aws:iam::YOUR_ACCOUNT:role/YOUR_APPLICATION_STACK-demo-deployer`. Keep `AWS_PROFILE=agent-gateway-dev` for application deployment, and never set `AWS_ADMIN_PROFILE` to the restricted deployer.

### Existing stack, or `AccessDenied` during deployment

Pulling a newer template does **not** update live IAM policies. If deployment reports `AccessDenied` (for example for `cloudformation:DescribeEvents`), update the access stack as an administrator:

1. Pull the latest `aws` branch with a clean checkout.
2. Run `make aws-access-deploy AWS_ADMIN_PROFILE=agent-gateway-admin`, or use the Console: CloudFormation → Europe (Paris) → select **`agent-gateway-access-dev`** (not the application stack `agent-gateway-dev`) → **Update stack → Create a change set → Replace existing template → Upload `deploy/aws/deployment-access.template.json`**.
3. Keep existing parameters, verify `DeploymentRole=AgentGatewayDev`, acknowledge named IAM resources, create the change set and **execute** it. Creating a change set alone applies nothing.
4. Wait for the **access stack** to show `UPDATE_COMPLETE`, then retry `make aws-deploy`.

If it still fails, inspect IAM → Roles → **AgentGatewayDev → Permissions** as administrator: the access stack's `DeploymentAccess` managed policy must be attached and its default version must include the missing action. Changing only the IAM user's permissions, or recreating the application, does not update the assumed role.

### Optional proxy VM permissions

The optional [proxy VM](Proxy-VM.md) is not part of the normal application deployment. Its stack is named `<application-stack>-proxy` (for example, `agent-gateway-dev-proxy`), separate from the `*-demo-*` stacks. The access template includes CloudFormation lifecycle and change-set permissions for that exact proxy-stack naming pattern, `ssm:GetParameters` on only the public Amazon Linux 2023 ARM64 AMI parameter, and region-limited AMI/VPC/Internet Gateway metadata reads. Separate `ProxyNetworkAccess` and `ProxyRoleAccess` managed policies scope VPC/Internet Gateway lifecycle and proxy IAM role/profile lifecycle. The role-creation permission requires a dedicated `ProxyRoleBoundary`, which caps the EC2 role at SSM core access and the exact application resources. `iam:PassRole` is limited to that generated proxy role and EC2. An already-deployed access stack does not receive these changes until an administrator updates it.

**An administrator must do this update.** Sign in to the AWS Console with an account administrator identity that can update CloudFormation and IAM; the restricted `agent-gateway-dev` deployment role cannot update its own access stack. This is a CloudFormation template upload, not an IAM inline-policy edit: do not paste this template or the separate `Test` policy into **IAM → Roles → AgentGatewayDev → Add inline policy**.

After the application stack is deployed, use the CLI command below instead of manually entering the proxy parameters in the CloudFormation console. It reads the exact bucket, API ID and licence object from `DemoConfiguration`, validates them, and passes them to CloudFormation; this avoids copy/paste and parameter-pattern errors:

```bash
make aws-access-deploy AWS_ADMIN_PROFILE=agent-gateway-admin
```

The command uses `AWS_PROFILE` (normally `agent-gateway-dev`) only to read the application stack and uses `AWS_ADMIN_PROFILE` to update the access stack. Ensure both profiles target the same `AWS_ACCOUNT`. Since the template is over CloudFormation's 51,200-byte direct-upload limit, the command stages it in S3. After the application exists, it uses the private activation bucket from `DemoConfiguration`; the administrator identity must be able to upload there. Before the application exists, set `AWS_ACCESS_S3_BUCKET` to an existing bucket in the same account where the administrator can upload, for example `make aws-access-deploy AWS_ADMIN_PROFILE=agent-gateway-admin AWS_ACCESS_S3_BUCKET=my-template-staging-bucket`. Review the CloudFormation change set and wait for `UPDATE_COMPLETE`. The parameter defaults in the template are deliberately nonfunctional placeholders; don't use the console to apply them after the application exists.

If a failed `agent-gateway-dev-proxy` stack already exists, first retry `make aws-proxy-delete` so CloudFormation can clean up its resources with the updated permissions. For a stack already in `ROLLBACK_FAILED` or `DELETE_FAILED`, the current template includes `ec2:DescribeVpcs` and `ec2:DeleteVpc` for the tagged proxy VPC. Do not manually delete stack-owned resources. Once the proxy stack is gone, retry `make aws-proxy-create` with `AWS_VM_PROFILE=agent-gateway-dev`.

The update adds lifecycle access only for the `agent-gateway-dev-proxy` stack name, read access to the public AMI parameter, and permissions for the proxy's VPC and Internet Gateway lifecycle, including VPC DNS-attribute modification, scoped by resource type, region and expected tags. It does not grant administrator access, general EC2/VPC resource-creation permissions, role trust-policy editing, or unrestricted role passing. The proxy role cannot exceed its boundary, even if its inline permissions are changed. If a later operation is denied, inspect the proxy stack's CloudFormation **Events** for the exact action and resource before changing any other policy. Do not add `AdministratorAccess`, `AmazonEC2FullAccess` or `IAMFullAccess`. The `aws-proxy-plan` command is offline sample output and does not check permissions.

These read-only checks use the default profile and stack names; adjust them if you chose others. They discover the policy ARN and version automatically:

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

The event check applies only once an application stack or change set exists; a missing-stack error is different from `AccessDenied`.

### Early validation failures and retained resources

If a change set fails with `AWS::EarlyValidation::ResourceExistenceCheck`, open the failed change set's **Deployment validations** tab in the administrator Console and inspect those events before retrying. The current template grants `cloudformation:DescribeEvents`, read-only `iam:GetPolicy` / `iam:GetPolicyVersion` on the exact workload boundary, and regional `logs:DescribeIndexPolicies` (AWS does not support log-group scoping for that action). An administrator must apply the updated template for these grants to take effect.

Deleting a stack does not delete resources marked `Retain`. Existing `agent-gateway-dev-domain` / `agent-gateway-dev-security` tables and named log groups will conflict with a fresh create. Preserve their data: either import the retained resources into the replacement stack first, or deliberately choose a separate deployment name and access configuration. Do not delete tables merely to clear validation errors.

Do not give the deployer permission to edit its own policies or attach `AdministratorAccess`. Remove the access stack only after workload cleanup.

## 6. Deploy the application (creates billable AWS resources)

Keep Docker running, then:

```bash
make aws-deploy
```

The script checks the selected account and profile, the current manifest, and live IAM prerequisites before any write. Missing boundary reads, log-index discovery or event diagnostics stop it immediately with the administrator recovery step. It then:

1. Creates or reuses private, versioned activation storage.
2. Uploads and pins your customer activation material.
3. Pulls the four signed-licence `_l` images and the prebuilt Emotion wrapper from Docker Hub into private ECR, checking every digest.
4. Generates CloudFormation parameters from your configuration and discovered S3 versions, including deploy-time JWT and operator secrets passed as `NoEcho` values.
5. Creates or updates the Lambda application, HTTP APIs, Cognito and DynamoDB through a change set.
6. Saves a teardown inventory, checks public and internal HTTP boundaries, and sends the first operator's Cognito invitation if needed.

JWT and operator secrets are generated once and stored in `dist/aws-lambda/plan/secrets.json` (mode 0600, Git-ignored). **Keep that file**: it preserves the same tokens across redeploys, and deleting it rotates both secrets and invalidates existing tokens and admin sessions. AWS Secrets Manager is the better production choice for rotation and audit; this demo avoids its per-secret monthly cost.

The parent deployment uses Lambda and managed services only; it creates no proxy VM or OpenClaw hosts. [Architecture](Architecture.md) covers single-region availability and limits. Bedrock configuration and permissions for the AI Wizard remain enabled, but successful model calls also depend on account and model availability.

**Expected:** the script prints **Deployment Complete**, the **ConsoleURL**, the baseline **GatewayURL**, the pool ID and the operator email. It saves endpoint identifiers to `dist/aws-lambda/plan/deployment-outputs.env` and a cleanup inventory under `dist/aws-lambda/teardown/`. Keep both for later cleanup and recovery.

`EnableRegoPolicy` defaults to `true`. This exposes **Policy & Rego** to signed-in administrators in the `AdminEmails` allowlist, enables per-delegation policy-engine selection in the Wizard, and stores managed revisions in DynamoDB. To disable those capabilities when preparing an image deployment, set `"enable_rego_policy": false` in the release configuration; the generated CloudFormation parameters then set `EnableRegoPolicy` to `false`. Existing and new delegations otherwise continue to use the built-in policy unless an administrator selects Rego. See [AWS demos](AWS-Demos.md#administrator-managed-rego-policy) for the editor, probes, and threshold guidance.

If deployment fails, open the named stack's CloudFormation **Events** and find the *first* underlying resource failure. Fix that, keep the inventory, and rerun with the same configuration. A printed plan or a created ECR repository alone does not mean the deployment succeeded.

## 7. Retrieve URLs without editing placeholders

```bash
make aws-outputs
```

This read-only command prints the stack status and labelled **Console**, **Baseline gateway** and **Sign in** URLs. Do not type an example API ID, append `/api` to it, or confuse the console with the gateway.

## 8. Open your console and sign in

Open the **Sign in** URL printed by `make aws-outputs` (the console URL followed by `/oidc/login?prompt=login`). The bare `*.auth.*.amazoncognito.com` domain is **not** the application login link.

Use your configured email and the invitation: enter the temporary password, then set your own when prompted. The initial account status is `FORCE_CHANGE_PASSWORD`. **Forgot password is not a substitute for a missing first invitation.** Do not use a local-demo password or AWS access key to sign in.

If the invitation is missing or expired, check spam, then the operator can request a fresh one (default profile and region):

```bash
source dist/aws-lambda/plan/deployment-outputs.env
aws cognito-idp admin-create-user --profile agent-gateway-dev --region eu-west-3 \
  --user-pool-id "$USER_POOL_ID" --username "$OPERATOR_EMAIL" \
  --message-action RESEND --desired-delivery-mediums EMAIL \
  --query 'User.UserStatus' --output text
```

Use the **newest** invitation's temporary password. A successful response means Cognito accepted the request, not that the email arrived. For an account that has already completed setup, use **Forgot password**. See [AWS administrator-created account guidance](https://docs.aws.amazon.com/cognito/latest/developerguide/how-to-create-user-accounts.html).

For an existing hosted deployment, get the ConsoleURL and invitation from its owner and skip all provisioning steps above.

## 9. Create the Users demo and its delegation

In the signed-in console:

1. Open **Protected APIs & MCP Servers** and click **AI Config Assistant (Freeride)**. This is not the separate **Delegation Wizard**.
2. Select the **Users REST API** preset and click **Ask Freeride AI to Generate**.
3. Review the generated configuration and choose **Open in 5-Step Wizard to Customize** (or deploy directly if offered).
4. Review the public JSONPlaceholder upstream, permit read access to `/api-users/users*`, and choose **Deploy Demo & Create Delegation**. Wait for the demo deployment to succeed.
5. Mint and copy an agent token for that Users delegation using the console's token controls. Keep it private.

Then, from this checkout:

```bash
make -s aws-demo-url DEMO=users
export GATEWAY_URL="$(make -s aws-demo-url DEMO=users)"
unset AGENT_TOKEN
make aws-demo DEMO=users
```

The first command prints the complete child URL; the export uses that exact value. When prompted for `Agent token:`, paste the token minted for the **Users REST API delegation** and press Enter. The terminal does not echo it. Do not use your Cognito password, AWS keys, an AWS session token, or Alice/Bob development-user data.

**Expected:** `PASS users access: HTTP 200`.

The child stack is `AWS_STACK-demo-api-users`; a missing-stack error means Users has not been deployed under your selected account, region and name. AccessDenied or expired-session errors need profile inspection or a fresh `aws login`. You can also copy the child's **GatewayURL** from CloudFormation **Outputs**, or ask the operator for it:

```bash
printf 'Paste the complete Users GatewayURL: '
read -r GATEWAY_URL
export GATEWAY_URL
unset AGENT_TOKEN
make aws-demo DEMO=users
```

A console URL, AWS credentials, a Cognito login token and an agent token serve different purposes. Never send an agent token directly to the public upstream provider. Each demo has its own gateway URL and matching delegation.

## 10. Test Emotion's approval sequence

Use the Wizard to deploy **Emotion** and create a delegation that allows `emotion_detection` and requires approval for `emotion_detection_detailed`. Mint its agent token, then switch endpoints:

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

**Expected:** the approved retry returns HTTP 200, and the next call is held again because approval is single-use. The published Emotion container enforces its own licence, so a native licence error in its MCP response is valid for testing the gateway but does not prove successful inference.

Revoke the delegation in the console before the token expires, then:

```bash
make aws-demo DEMO=emotion PHASE=revoked
```

**Expected:** HTTP 403. [All demos](AWS-Demos.md) covers weather, geocoding and refunds, optional-token delivery and baseline weather routes. For paid Emotion inference, follow [Paid Emotion activation](AWS-Demos.md#paid-emotion-activation); gateway evaluation licences do not grant an Emotion licence.

## 11. Optional infrastructure is a separate decision

No proxy is needed for the five Lambda API/MCP presets. If you deliberately want a forward-proxy/CONNECT demo, read [Proxy VM](Proxy-VM.md) first: it has explicit create, connect and delete commands and ongoing EC2, storage and IPv4 costs. Do not create one merely to test Users or Emotion.

OpenClaw/OpenShell and custom stateful backends are **not** provisioned by these scripts. See [customer-managed hosts](Customer-Managed-Demos.md) if you later supply them yourself.

## 12. Finish and clean up

**Administrator credentials:** if you used access keys in step 2B, deactivate and delete them in IAM → Users → `agent-gateway-admin` → Security credentials once the access stack is in place. You only need administrator access again to update the access stack and for final access cleanup; create a fresh key or sign in again then.

**Hosted or shared deployment:** revoke your test delegations, run `unset AGENT_TOKEN`, sign out, and leave resource cleanup to the owner.

**Your own deployment:** use [Teardown](Teardown.md). It separates demo deletion, parent removal with retained data, permanent purge, ECR removal and final administrator access cleanup. Closing the console or terminal does not remove billable resources.

### Demo signing secrets

The signed-licence web function receives the same JWT signing value and operator value as the parent gateway. The wizard passes them to child stacks as separate `NoEcho` parameters; they never appear in `DemoConfiguration` outputs or child template bodies. Keep the private local `dist/aws-lambda/plan/secrets.json` for updates. The published web image handles this provisioning path; customers do not rebuild images or use the private source CLI.

## 13. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Your session has expired. Please reauthenticate using 'aws login'` | The `aws login` session for that profile timed out | `aws login --profile agent-gateway-user` (the role profile reuses it) |
| `Profile 'default' is already configured with Access Key credentials` | `aws login` ran without `--profile` and hit `default`, which holds static keys | Pass `--profile <name>`, or remove the keys from `default` |
| `The config profile (...) could not be found` | `AWS_ADMIN_PROFILE` was given an account ID or email | Pass a profile *name* that exists in `~/.aws/config` or `~/.aws/credentials` |
| `Administrator profile/account mismatch` | The admin profile does not exist or targets a different account | Fix the profile name, then confirm `get-caller-identity` shows `AWS_ACCOUNT` |
| `aws login --profile agent-gateway-admin` says it used `user/agent-gateway-dev` credentials | The browser was already signed in as the restricted user | Use access keys (step 2B, method 1), or sign out everywhere and use `--remote` in a fresh private window |
| `get-caller-identity` for the admin profile shows `user/agent-gateway-dev` | That profile is not an administrator | Rebuild it as in step 2B and verify before using it |
| `aws: [ERROR]: 'Status'` during `aws-access-deploy` | Not fully diagnosed. It appeared when the profile used `aws login` session credentials, and the same command succeeded later with static access keys, so it may be a CLI/credential-provider problem rather than a permissions one | Retry with a profile that resolves to a verified administrator using access keys or SSO; add `--debug` to see the underlying error |
| `iam:get-policy ... ARN ... is not valid` during `aws-deploy` | `WORKLOAD_BOUNDARY_ARN` holds the wrong value (for example the `demo-deployer` role ARN) or has a trailing space | Set it to the `WorkloadBoundaryArn` policy ARN from the access stack outputs, with no trailing space, or leave it empty and set `AWS_ADMIN_PROFILE` |
| `get-caller-identity` for `agent-gateway-dev` shows `user/...` instead of `assumed-role/AgentGatewayDev/...` | A static-key section `[agent-gateway-dev]` in `~/.aws/credentials` overrides the role profile | Delete that section from `~/.aws/credentials` and run `aws login --profile agent-gateway-user` |
| `AssumeRole` access denied | Role trust policy, `sts:AssumeRole` permission or MFA missing | Administrator reviews the trust policy of `AgentGatewayDev` |
| `AccessDenied` on `cloudformation:DescribeEvents` or similar during deploy | The live IAM policy is older than the template | Update the access stack and **execute** the change set ([step 5](#existing-stack-or-accessdenied-during-deployment)) |
| `AWS::EarlyValidation::ResourceExistenceCheck` | A retained table or log group conflicts, or diagnostics permission is missing | See the early-validation notes in step 5 |
| A teardown inventory refers to an earlier CloudFormation stack ID with the same stack name | The stack was deleted and recreated, but the prior cleanup inventory remains | The teardown tool now keeps each verified stack generation in the inventory and adds the current stack ID. Review every generation in the plan; use `--state-file` to separate inventories only when managing unrelated cleanup histories |
| After deleting and redeploying, a retained resource has a different ID than the old inventory | Retained DynamoDB tables and log groups keep their names and are reused by the new stack, but a Cognito user pool is created fresh, leaving the old one orphaned | Compare with `aws cloudformation list-stack-resources --stack-name <app stack> --query "StackResourceSummaries[?ResourceType=='AWS::DynamoDB::Table' \|\| ResourceType=='AWS::Cognito::UserPool'].[LogicalResourceId,PhysicalResourceId]"`. Delete an orphaned pool manually only after confirming it holds nothing you need |
| No invitation email | Spam folder, or the original expired | Resend with the command in step 8 |

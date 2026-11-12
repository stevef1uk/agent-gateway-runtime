# Running demos against AWS

Additional OpenClaw/OpenShell and backend hosts are customer-managed; supplied scripts do not provision them. Follow [customer-managed demo host setup](Customer-Managed-Demos.md) when you choose to run those integrations.

The selected design uses a single-region serverless control plane and dedicated Lambda policy enforcement gateways for API/MCP demos. A separate EC2 forward proxy is optional. Creating a demo in the AI Wizard does not start that VM.

## Which demos need the proxy?

| Demo | Endpoint/backend | Proxy VM required first? | Additional prerequisite |
|---|---|---|---|
| Weather | Dedicated Lambda gateway → Open-Meteo | **No** | Deploy `weather` API demo; grant forecast read access |
| Geocoding | Dedicated Lambda gateway → Open-Meteo geocoding | **No** | Deploy `geocoding` API demo; grant search read access |
| Users | Dedicated Lambda gateway → JSONPlaceholder | **No** | Deploy `users` API demo; grant users read access |
| Refunds simulation | Dedicated Lambda gateway → JSONPlaceholder `/posts` | **No** | Deploy `refunds` API demo; grant create access and review approval/value rules; no financial transaction occurs |
| Emotion | Dedicated Lambda gateway → private Lambda containing published Emotion API and MCP images | **No** | Deploy `emotion` MCP demo; allow basic detection and require approval for detailed detection |
| HTTP forward-proxy access | EC2 proxy → public HTTP destination | **Yes** | Create VM, open SSM tunnel, grant destination/resource and action |
| HTTPS CONNECT / long-lived connections | EC2 proxy → public HTTPS destination | **Yes** | Same VM/tunnel; grant CONNECT destination. TLS remains end-to-end; inner HTTP methods/body are not inspected |
| Gmail, orders or other custom/stateful integrations | Integration-specific backend | **Depends on connection mode** | A forward-proxy client needs the VM. An API/MCP gateway client does not. Supply the actual backend, credentials/OAuth and persistent storage separately; the proxy VM does not install those services |

The old local `demo.sh`/Docker Compose workflow uses local services and admin endpoints. It cannot be run unchanged against AWS. Use the AWS runners below; approvals and revocation happen in the signed-in AWS console. A proxy is a transport component, not a replacement for a missing stateful backend.

For the numbered main-branch demos (purchasing, OPA, OpenClaw/OpenShell, invoice, CRM, DPoP, kill switch, approval edges and Gmail), see the [migration compatibility matrix](Main-Demo-Compatibility.md). These workflows have additional local backend/sandbox assumptions; the AWS clients below cover the listed presets and HTTP proxy probe, rather than claiming every unchanged main-branch script works on AWS.

## Administrator-managed Rego policy

The AWS Console includes the Rego editor and live decision probes when the deployment's `EnableRegoPolicy` CloudFormation parameter is `true` (the default). Sign in with an email in the deployment's `AdminEmails` allowlist, then open **Policy & Rego** in the Console header. The editor validates changes with OPA, stores versioned policy revisions in the stack's DynamoDB domain-state table, and restores the bundled policy or a prior saved revision. Authorization Lambda environments poll shared policy state; a cold environment loads the current policy on startup.

The Delegation Wizard's **Authorization policy engine** choice is saved on each delegation: **Built-in delegation policy** remains the default, while **Rego (OPA)** uses the operator-managed Rego policy. Older delegations without a saved choice continue to use the built-in policy. The editor's Decision probes create a short-lived Rego-enabled probe delegation and send editable requests to the authorization service; they do not call an upstream API or execute an action. The page also explains how to change the spend approval threshold and makes clear that a policy-wide threshold affects every Rego-enabled delegation.

## Emotion image and licence renewal

Use the dedicated `linux/arm64` Lambda Emotion wrapper for AWS; it retrieves the vendor-issued signed licence token from a versioned S3 object. The model image is not encrypted and does not require a customer private key. A renewed licence is activated through `make aws-emotion-activate`; licence material is not baked into the image.

## Provision API/MCP demos

Open your deployed console and sign in. For the documented API/MCP presets, open **Protected APIs & MCP Servers**, click **AI Config Assistant (Freeride)**, select the desired preset (for example **Users REST API**), and click **Ask Freeride AI to Generate**. Review the generated configuration, then choose **Open in 5-Step Wizard to Customize** or deploy directly if offered, followed by **Deploy Demo & Create Delegation**. This is different from the separate **Delegation Wizard**, which does not list every guided AWS preset. Wait for the demo deployment to succeed before running a client. The parent installation must already include the deployment role and image configuration supplied by its owner.

After changing presets, generate a fresh configuration before deploying. Selecting a preset alone only fills the prompt. Weather and Geocoding need no paid Emotion licence or proxy VM.

Create/review the matching delegation and mint its agent token in the console. API resources use `/api-NAME/...`; MCP resources use `/mcp-NAME`. Do not reuse the baseline weather gateway URL for a different child demo. Customers use prebuilt vendor images; image publication belongs to the vendor release process.

If you do not yet have a console/invitation, start with [Self-hosting prerequisites](Self-Hosting.md) or ask your hosted-deployment operator. No private source repository access is required to run these clients.

## Paid Emotion activation

Emotion inference requires a vendor-issued licence token. Contact [Emotion Service API sales](https://emotion-service-api.sjfisher.com) or sales@sjfisher.com. Publishing or pulling the image does not grant a paid licence. Customers never receive the vendor signing key, and another customer's activation files must never be reused or published.

1. Deploy the **Emotion** MCP preset in the Wizard and wait for success.
2. Save your issued token as `keys/local-activation/emotion.token`. This directory is Git-ignored; do not overwrite tracked example files or paste credentials into the console tester.
3. From this checkout, activate your own deployment:

```bash
make aws-emotion-activate \
  EMOTION_TOKEN_FILE=keys/local-activation/emotion.token
```

The Wizard creates the backend, but licensed inference is not ready until this activation command succeeds. It uploads the token privately to your account's encrypted, versioned activation bucket, pins only the Emotion backend to that version, and warms the model. The script refuses to continue if the bucket does not return a real object version. To deploy a newly published wrapper image at the same time, pass its immutable ECR digest with `EMOTION_IMAGE_URI=...`. Gateway signing values and existing gateway key versions are preserved. Only the vendor runtime validates the licence. The token stays outside Git, images, and public manifests.

To clear an external token override and use the evaluation licence already bundled with the vendor image, run `make aws-emotion-restore-bundled`. This changes only the Emotion child stack, uploads no token, clears the pinned token version, and warms the model. Optionally pass `EMOTION_IMAGE_URI=...` to restore a specific immutable image digest.

4. Use your Emotion delegation's agent token in the Console Endpoint Tester or the Emotion client. Payment/licensing does not replace gateway authorization; a public gateway URL alone does not grant inference access.

First activation/cold startup loads the model and can take tens of seconds or longer; one AWS warmup took approximately 55 seconds. Subsequent inference can be much faster. These are observations, not latency guarantees. The activation command waits for both API and model readiness. A concurrent console call can start a second cold Lambda environment, so wait for warmup to finish before testing. If a tool call arrives before readiness, the backend returns HTTP 503 with `Retry-After` instead of forwarding it into a connection-refused response.

If you recreate/redeploy the Emotion demo in the Wizard, rerun activation. Renew expired licences through the vendor and rerun the same command. A `License Required` MCP response can also wrap a backend connection failure: inspect its parenthesized detail. `127.0.0.1:8080/completion: connection refused` indicates the model server is unavailable, not proof that the token expired. Use the current release, which aligns API/model ports and readiness checks.

This repository automates activation, not checkout or licence issuance. Keep payment approval and issuance under your control. Hosted deployments must separately enforce each paying customer's identity/delegations; sharing one licensed backend does not provide customer licence isolation.

## Run API/MCP probes

From **agent-gateway-runtime** on branch `aws`, first retrieve the selected child demo's complete public **GatewayURL**. Each demo has a different API Gateway ID. Copy the whole URL; do not construct it by editing an API ID, use the console URL, append a route, or reuse another demo's URL.

### Find the URL with Make (recommended)

Prerequisites: AWS CLI authenticated with permission to describe the selected child stack, plus that demo already deployed successfully. Defaults are profile `agent-gateway-dev`, region `eu-west-3`, parent stack `agent-gateway-dev`.

```bash
# Print the actual Users endpoint (read-only; does not deploy anything).
make -s aws-demo-url DEMO=users
# Capture the same complete URL for the client.
export GATEWAY_URL="$(make -s aws-demo-url DEMO=users)"
unset AGENT_TOKEN
make aws-demo DEMO=users
```

The script asks privately for the **agent token from your Users delegation**. Create/review that delegation in the signed-in console first, allowing read access to `/api-users/users*`, and mint/copy its agent token. Paste that token at the `Agent token:` prompt and press Enter; the terminal intentionally does not echo it. Do not supply AWS access keys, your Cognito password or sign-in token, Alice/Bob development-user data, or a token for another demo. `unset AGENT_TOKEN` makes the client prompt rather than reuse a token left in your shell.

If AWS reports that the stack does not exist, deploy that demo using the Wizard, and wait for success. If AWS reports AccessDenied or an expired session, resolve access for the selected profile; this lookup does not grant permissions or create resources. A missing GatewayURL after creation means deployment needs inspection before testing.

For another environment, apply the same settings to every lookup:

```bash
export AWS_PROFILE=your-profile AWS_REGION=your-region AWS_STACK=your-parent-stack
make -s aws-demo-url DEMO=users
```

### Find the URL in the AWS console

Open **CloudFormation** in the deployment region, select the child stack, open **Outputs**, and copy the value beside **GatewayURL**. With the default parent name, the stacks are:

| Demo | Child stack |
|---|---|
| Users | `agent-gateway-dev-demo-api-users` |
| Weather | `agent-gateway-dev-demo-api-weather` |
| Geocoding | `agent-gateway-dev-demo-api-geocoding` |
| Refunds | `agent-gateway-dev-demo-api-refunds` |
| Emotion | `agent-gateway-dev-demo-mcp-emotion` |

For a different parent name or service slug, ask the deployment owner for the matching child stack or GatewayURL. Select a completed child deployment, rather than the parent's baseline gateway or public web console.

### Switch demos explicitly

Retrieve the URL again and use the matching delegation token each time:

```bash
export GATEWAY_URL="$(make -s aws-demo-url DEMO=weather)"
unset AGENT_TOKEN
make aws-demo DEMO=weather

export GATEWAY_URL="$(make -s aws-demo-url DEMO=geocoding)"
unset AGENT_TOKEN
make aws-demo DEMO=geocoding

export GATEWAY_URL="$(make -s aws-demo-url DEMO=refunds)"
unset AGENT_TOKEN
make aws-demo DEMO=refunds

export GATEWAY_URL="$(make -s aws-demo-url DEMO=emotion)"
unset AGENT_TOKEN
make aws-demo DEMO=emotion PHASE=access
```

Run each command against its own demo URL and matching delegation. Default paths are `/api-weather/v1/forecast`, `/api-geocoding/v1/search`, `/api-users/users/1`, `/api-refunds/posts` and `/mcp-emotion`. Refunds sends a simulated amount of 25 and expects HTTP 201 from JSONPlaceholder; choose approval rules to match the phase you run. The runner fails on unexpected statuses rather than treating all responses as success.

For Emotion, allow `emotion_detection` and hold `emotion_detection_detailed`:

```bash
make aws-demo DEMO=emotion PHASE=access
make aws-demo DEMO=emotion PHASE=held
# Approve the reported request in the signed-in console.
make aws-demo DEMO=emotion PHASE=approved
make aws-demo DEMO=emotion PHASE=held  # single-use approval is consumed
# Revoke this delegation in the console before the agent token expires.
make aws-demo DEMO=emotion PHASE=revoked
```

The published Emotion container enforces its own licensing. Its native MCP error is an acceptable upstream result after the gateway authorizes the call. The runner prints that response for inspection; HTTP 200 alone does not establish that inference succeeded. The gateway has no additional Emotion licence check.

For REST demos, `PHASE=held` expects 202 and an approval ID; `PHASE=approved` expects the provider's successful response; `PHASE=revoked` expects 403. Configure the selected operation's delegation approval rule before using held/approved. The existing `make demo` weather tutorial remains available for the **baseline** gateway's unprefixed `/v1/...` routes and its forecast/elevation approval sequence.

## Start the proxy before forward-proxy demos

The proxy must first be created explicitly by the deployment owner from this runtime checkout. Follow [Proxy VM](Proxy-VM.md): configure AWS_VM_PROFILE, then use `make aws-proxy-create`, `make aws-proxy-status` and `make aws-proxy-connect`. These commands use the public scripts/templates in this repository; no source checkout is needed. The five Lambda demo presets need no proxy.

For a proxy already created by your operator, obtain its instance ID/region and approved SSM session access. Open the SSM port-forwarding tunnel to proxy loopback port 8088, following [AWS instructions](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-start.html). Keep that terminal open. The local URL should be `http://127.0.0.1:8088`; do not expose a public proxy port.

In another terminal, from **agent-gateway-runtime**, use a delegation with tool `egress`, resource `example.com`, and action `read` (HTTP GET):

```bash
make aws-demo DEMO=proxy PHASE=access
# Revoke that delegation in the console, then:
make aws-demo DEMO=proxy PHASE=revoked
```

This runner exercises ordinary HTTP forward-proxy access. For HTTPS CONNECT, use a delegation scoped to the CONNECT destination and a client configured with the local proxy. An explicit curl example is:

```bash
# AGENT_TOKEN must contain the matching proxy delegation token.
curl --noproxy '' --proxy http://127.0.0.1:8088 \
  --proxy-header "Proxy-Authorization: Bearer $AGENT_TOKEN" https://example.com/
```

A held CONNECT returns an HTTP proxy response before the TLS tunnel is established; curl may report tunnel failure even when the policy correctly requested approval. Inspect the proxy status, approve in the console, and retry. A CONNECT grant controls destination access, not API methods inside encrypted TLS. The HTTP demo runner does not claim to test CONNECT or an application's stateful protocol.

## Stop paying for the optional VM

Closing the SSM terminal only closes the tunnel. It does **not** delete or stop the VM.

The deployment owner runs `make aws-proxy-delete` from this runtime checkout to delete the optional proxy stack. Customer-managed OpenClaw/backend hosts must be deleted through their own management procedure. The client runner deletes neither.

The proxy deletion procedure should wait for stack removal and remove its instance, encrypted root disk and owned network. Shared application tables, secrets, images and demo stacks are separate. EC2 compute, EBS and public IPv4 can incur ongoing charges while provisioned. Review [cleanup ownership](Teardown.md).

## Availability of this design

API Gateway, Lambda and DynamoDB provide managed regional availability. The scripts select one region and do not configure cross-region failover, DynamoDB global tables, reserved concurrency or guaranteed warm capacity. DynamoDB persists authorization/catalogue state; an in-flight request can still fail and require retry.

The optional proxy is **one instance in one Availability Zone** with a systemd restart policy. It has no load balancer, Auto Scaling replacement or second instance. A host/AZ failure interrupts proxy service and active connections; systemd restart is not infrastructure failover. Stateful applications need their own durability and recovery design.

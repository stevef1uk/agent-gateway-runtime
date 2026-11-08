# Running demos against AWS

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

## Provision API/MCP demos

From the **agent-gateway source repository**, after deploying the wizard-enabled parent stack and its reviewed deployment-access role:

```bash
make aws-demo-deploy DEMO=weather DEMO_KIND=api
make aws-demo-deploy DEMO=geocoding DEMO_KIND=api
make aws-demo-deploy DEMO=users DEMO_KIND=api
make aws-demo-deploy DEMO=refunds DEMO_KIND=api
make aws-demo-deploy DEMO=emotion DEMO_KIND=mcp
make aws-demo-list
```

Alternatively, use **Deploy Demo & Create Delegation** in the AI Wizard. CLI provisioning creates the backend and gateway; it does not issue a delegation. Create/review the delegation in the console, then copy its agent token privately. The caller must have the demo's exact `/api-NAME/...` or `/mcp-NAME` resources and appropriate actions. Do not substitute the baseline weather gateway URL for a child demo's gateway URL.

## Run API/MCP probes

From **agent-gateway-runtime**, set `GATEWAY_URL` to that demo's public **GatewayURL** from `make aws-demo-list` or the child stack outputs. Use the HTTPS execute-api origin without a path. The runner prompts privately for the agent token if `AGENT_TOKEN` is absent.

```bash
export GATEWAY_URL='https://REPLACE.execute-api.eu-west-3.amazonaws.com'
make aws-demo DEMO=weather
make aws-demo DEMO=geocoding
make aws-demo DEMO=users
make aws-demo DEMO=refunds
make aws-demo DEMO=emotion
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

Run from **agent-gateway** (runtime provides wrappers for these same targets). Select an explicitly reviewed non-root deployment profile with EC2, IAM, CloudFormation and SSM permissions; the application deployment profile is not automatically granted those permissions.

```bash
make aws-proxy-plan  # offline parameter preview; creates nothing
make aws-proxy-create AWS_VM_PROFILE=YOUR_VM_PROFILE
make aws-proxy-status AWS_VM_PROFILE=YOUR_VM_PROFILE
make aws-proxy-connect AWS_VM_PROFILE=YOUR_VM_PROFILE
```

Keep the connect terminal open. The Session Manager plugin must be installed for port forwarding. The tunnel exposes only `http://127.0.0.1:8088` locally. The VM security group opens no inbound ports, including SSH or a public proxy port.

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

```bash
# From agent-gateway, or through the runtime wrapper:
make aws-proxy-delete AWS_VM_PROFILE=YOUR_VM_PROFILE
```

Deletion waits for the proxy stack to disappear and removes its instance, encrypted root disk and owned network resources. Shared application tables, secrets, images and demo stacks are retained. Delete the optional proxy **before** deleting the parent application. EC2 compute, EBS and public IPv4 incur ongoing charges while provisioned; standard burstable CPU credits are used. Other shared AWS services can still incur charges after proxy deletion.

## Availability of this design

API Gateway, Lambda and DynamoDB provide managed regional availability. The scripts select one region and do not configure cross-region failover, DynamoDB global tables, reserved concurrency or guaranteed warm capacity. DynamoDB persists authorization/catalogue state; an in-flight request can still fail and require retry.

The optional proxy is **one instance in one Availability Zone** with a systemd restart policy. It has no load balancer, Auto Scaling replacement or second instance. A host/AZ failure interrupts proxy service and active connections; systemd restart is not infrastructure failover. Stateful applications need their own durability and recovery design.

# Customer-managed hosts for advanced demos

OpenClaw/OpenShell, CRM, Gmail connectors and other stateful demo backends are **customer-managed components**. The supplied AWS scripts do not create their hosts. There is no OpenClaw VM Make target, and running the API/MCP presets does not provision one. The separately supplied optional proxy VM provides transport only.

This guide describes a deployment path a customer can carry out later. Reading it or running the ordinary offline checks creates no resources. No additional host is needed to exercise the supplied weather, geocoding, users, refunds simulation or Emotion presets.

## 1. Choose and provision your own host

Use an existing compatible workstation/server, or provision a VM in your own account when ready. Follow the [AWS EC2 launch/connect/cleanup guide](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/EC2_GetStarted.html) if choosing EC2. You own its sizing, OS updates, backups, availability and costs.

For an EC2 host:

* Select an OS and CPU architecture supported by your chosen OpenShell driver, container images and application release. Size memory/disk/CPU for the actual workload; the optional proxy's small ARM64 instance is not a sizing recommendation for OpenClaw or model inference.
* Use encrypted storage, IMDSv2 and a dedicated instance role. Give the host only the access its workload needs. Do not copy application deployment credentials or administrator keys into the sandbox.
* Arrange management access, preferably Session Manager with the required agent/role/network connectivity. Keep sandbox dashboards and container/management ports private; use a tunnel for operator access.
* Provide outbound access to approved package/image registries and model/tool providers. A private subnet may need endpoints or paid NAT; include that cost in your design. A host without a public management port still needs working outbound connectivity.
* Tag and record everything you create: VM, disks, snapshots, addresses, network resources and any model service. A customer-hosted single VM has no automatic HA merely because it calls the managed AWS gateway.

For OpenShell and OpenClaw installation, use the current [OpenShell installation instructions](https://docs.nvidia.com/openshell/latest/about/installation), [agent setup guide](https://docs.nvidia.com/openshell/latest/about/run-your-first-agent) and [OpenClaw installation requirements](https://docs.openclaw.ai/install). Select compatible releases and record their versions/digests. GPU/local-model infrastructure is a separate decision; using a remote model endpoint still requires provider credentials and can incur inference charges.

## 2. Prepare the sandbox separately

Use a separate checkout of `agent-gateway-runtime` **main** on the customer host. Keep the `aws` checkout for the AWS clients and documentation. Pin a reviewed commit rather than silently combining scripts from different revisions.

The main-branch recipe is `demo/openclaw-sandbox.sh`, with its `demo/openclaw/` build context and supporting scripts. Review them against the selected upstream releases first: the inspected recipe uses Node 22, so verify/update its runtime and OpenClaw package pin against current upstream requirements before building. The AWS branch does not certify this recipe with every newer OpenShell/OpenClaw release.

After that compatibility review, the recipe's sandbox-only sequence is:

```bash
# In your separately reviewed main-branch runtime checkout, on your own host:
bash demo/openclaw-sandbox.sh build
bash demo/openclaw-sandbox.sh up
# Supply model-provider settings privately as described by that script.
bash demo/openclaw-sandbox.sh configure
bash demo/openclaw-sandbox.sh status
bash demo/openclaw-sandbox.sh chat 'Hello'
```

This stage proves the sandbox/model provider independently. It does not establish Agent Gateway authorization. The recipe's `stack-up` and `chat-gateway` paths start/configure a local stack; the older egress harness also contains local admin/auto-approval assumptions. Do not use those paths as an AWS integration procedure. Use console-created delegations and human approval instead.

## 3. Choose how the agent reaches governed tools

| Connection mode | Need optional AWS proxy running? | Customer configuration |
|---|---|---|
| Explicit HTTPS API/MCP tool call | **No** | Point that tool at its child GatewayURL and governed `/api-NAME/...` or `/mcp-NAME` route; attach the matching agent token |
| General outbound HTTP or HTTPS CONNECT | **Yes** | Start the optional proxy and establish a reachable tunnel; configure the actual sandbox egress supervisor/client to use it with a scoped proxy delegation |
| OpenShell's own network policy only | **No** | Enforces the sandbox's policy, but does not demonstrate Agent Gateway authorization or approval |

**Direct tools:** configure a tool adapter/client that supports the gateway's HTTP/MCP interface and token delivery. Supply the token through the client's secret mechanism, not the model prompt. Set exact method/resource scopes and any approval rules in the AWS console. Calling a public upstream directly bypasses the gateway even when the sandbox itself is isolated. Custom CRM/Gmail/invoice tools still need their separately hosted backend, OAuth credentials and durable state.

**Forward proxy:** create the optional proxy only when you choose to exercise this mode, using [the proxy lifecycle](../../agent-gateway/docs/aws/proxy-vm.md). Run the SSM port-forwarding client **on the customer sandbox host** so its loopback listener is reachable there. Use a dedicated non-root profile/session allowed to start an SSM session to that proxy instance, rather than passing a VM deployment role into the sandbox. Follow [AWS Session Manager port-forwarding instructions](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-start.html).

An SSM tunnel on your laptop is not automatically available on a remote VM. Likewise, `127.0.0.1:8088` inside a container is the container itself, not the host's tunnel. Configure a private, reachable bridge/forwarder or supported upstream-proxy setting for the selected OpenShell driver; verify it from the actual egress process. Do not solve this by publishing an unauthenticated proxy to the internet. OpenShell upstream-proxy configuration and credential handling vary by version; use that version's supported settings rather than assuming a generic `HTTPS_PROXY` variable overrides its supervisor.

The proxy expects `Proxy-Authorization: Bearer AGENT_TOKEN`. Its supplied VM configuration does not enable the local demo's Basic-auth integration. If the chosen sandbox driver cannot supply that Bearer header, use a customer-managed credential-aware adapter or choose direct API/MCP tools; do not claim the integration works merely because the host curl probe passes.

## 4. Prove the selected path before running the agent

First use the [AWS demo probes](AWS-Demos.md) from the same host/network context as the client. For direct tools, check an allowed call, an out-of-scope denial, a held call, a human-approved retry and revocation. Then repeat from the sandbox/client itself; host connectivity alone does not prove sandbox routing.

For proxy delegation, use tool `egress`, the destination hostname as resource, and the required `read` or `connect` action. Check both allowed and disallowed destinations. Hold a selected operation and approve it in the console, then verify a subsequent call is denied after delegation revocation. Confirm the corresponding audit entries.

HTTPS CONNECT authorizes a destination when establishing a tunnel. It does not inspect API methods or payloads inside TLS, and delegation revocation does not terminate an already-open connection. Use direct API/MCP calls for per-operation approval. Restrict alternative egress paths in the sandbox/network if the goal is whole-runtime governance.

## 5. Delete what you created

When finished, stop the sandbox using the reviewed recipe's `down` command and revoke disposable delegations/provider credentials. That stops the sandbox, **not the customer's VM**.

Terminate the customer-created VM through its own management/IaC procedure and review leftover EBS volumes, snapshots, public addresses, NAT gateways, load balancers and model services. Stopping an EC2 instance can leave chargeable storage/network resources. Retain any application state deliberately before deletion.

If you separately created our optional proxy, delete it with `make aws-proxy-delete AWS_VM_PROFILE=YOUR_VM_PROFILE`. That command removes only the supplied proxy stack; it cannot discover or clean up your OpenClaw host or custom backend infrastructure. Closing a tunnel deletes neither VM. The standard application cleanup likewise does not manage customer-created hosts.

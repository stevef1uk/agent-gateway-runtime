# Optional AWS forward-proxy VM

**Skip this for Weather, Geocoding, Users, Refunds and Emotion.** Their direct API/MCP gateways use Lambda. Create this separate VM only for forward-proxy/HTTPS CONNECT or long-lived connection demonstrations you deliberately choose to run.

## Prerequisites

Complete the parent deployment using the [customer guide](Deployment-Guide.md), and install the AWS Session Manager plugin. The template and scripts are already in this repository; **do not create or edit `proxy-vm.template.json`**.

The VM uses the existing restricted deployment profile for the proxy stack. In ignored `aws-config.mk`, the current setup uses:

```make
AWS_PROFILE = agent-gateway-dev
AWS_VM_PROFILE = agent-gateway-dev
```

Before creating the VM, an administrator must update the `agent-gateway-access-dev` CloudFormation stack with the latest `deploy/aws/deployment-access.template.json`, as described in [Optional proxy VM permissions](Deployment-Guide.md#optional-proxy-vm-permissions). Run `make aws-access-deploy AWS_ADMIN_PROFILE=agent-gateway-admin`; the script reads and validates the exact activation bucket, authorization API ID and licence object from the parent stack's `DemoConfiguration` output, and resolves the current public Amazon Linux AMI ID using the administrator profile. This is not an IAM inline-policy edit, and the restricted `agent-gateway-dev` role cannot update the access stack. The update grants the CloudFormation lifecycle scope for `agent-gateway-dev-proxy`, read access to the exact public Amazon Linux 2023 ARM64 AMI parameter, and region-limited AMI/VPC/network metadata reads. `RunInstances` is authorized only for that exact resolved AMI ID. It also creates `ProxyNetworkAccess`, `ProxySubnetRouteAccess`, `ProxyLaunchTemplateAccess`, `ProxyInstanceAccess`, `ProxyRoleBoundary`, and `ProxyRoleAccess` managed policies. Network and compute permissions are constrained by resource type, expected tags, allowed instance types, and encrypted root-volume settings; role creation requires the boundary, and `iam:PassRole` is limited to the generated proxy role and EC2. The boundary limits the VM role to SSM core access and the exact application resources. The security group retains AWS's default allow-all outbound behavior by omitting explicit egress rules; no inbound rules are opened. If the create command then reports another `AccessDenied`, stop and inspect the proxy stack's CloudFormation Events for the exact denied action; do not add broad policies or switch to root for the create command.

If a create attempt leaves the proxy stack in `ROLLBACK_COMPLETE`, `ROLLBACK_FAILED` or `DELETE_FAILED`, update the access stack with the latest template first, then retry `make aws-proxy-delete`. The proxy access policies include regional resource discovery and tag-scoped cleanup for its VPC, subnet, route table, security group, launch template, and instance. Do not manually delete individual resources owned by the proxy stack; let CloudFormation clean them up. Create again only after `agent-gateway-dev-proxy` is gone.

```bash
aws --profile agent-gateway-dev --region eu-west-3 sts get-caller-identity
```

The create script reads the live parent configuration and checks the account; you do not need to copy deployment IDs or secrets into the template.

## Create and connect

You can skip `make aws-proxy-plan`: it is an offline illustration with fake example values, not a plan for your account. To create the optional, billable VM and open the tunnel:

```bash
make aws-proxy-create
make aws-proxy-status
make aws-proxy-connect
```

Keep the `aws-proxy-connect` terminal open while testing. It forwards `http://127.0.0.1:8088` from your workstation to the proxy VM in AWS using SSM. No SSH or inbound proxy port is opened. Use the [proxy demo probe](AWS-Demos.md) with its own egress delegation token.

The default is one `t4g.small` ARM64 instance, standard CPU credits and a 12 GiB encrypted gp3 root disk deleted on termination. `PROXY_INSTANCE_TYPE=t4g.medium` is available. The VM owns a small VPC/public subnet/internet route and uses a public IPv4 address for outbound access. No NAT gateway, load balancer or Auto Scaling group is created. It has **single-instance, single-AZ availability**, with only systemd process restart; active connections are lost on host failure/restart.

## Tutorial: call a real HTTPS API through the proxy

This example calls the public [Open-Meteo forecast API](https://open-meteo.com/) over HTTPS. It needs no upstream API key; the Agent Gateway egress token is still required.

1. Follow [Create and connect](#create-and-connect) above. Do not use the example plan values for live resources.
2. In the signed-in Agent Gateway Console, create an egress delegation scoped to tool `egress`, resource `api.open-meteo.com`, and action `connect`; mint an agent token for that delegation. The resource is the hostname only: do not include `https://`, a path, or a query string. Use a policy that allows this connection for the test.

3. In another workstation terminal, enter the token without putting it in shell history or curl's command-line arguments, then send the HTTPS request through the SSM tunnel:

   ```bash
   read -r -s -p 'Proxy delegation token: ' PROXY_TOKEN
   printf '\n'
   printf 'proxy = "http://127.0.0.1:8088"\nproxy-header = "Proxy-Authorization: Bearer %s"\n' "$PROXY_TOKEN" |
     curl -q --config - --noproxy '' --fail-with-body --silent --show-error \
       --write-out '\nHTTP %{http_code}\n' \
       'https://api.open-meteo.com/v1/forecast?latitude=51.5072&longitude=-0.1276&current=temperature_2m'
   unset PROXY_TOKEN
   ```

   The proxy setting points curl at the local end of the SSM tunnel. The URL is still the real HTTPS Open-Meteo API; the AWS EC2 proxy opens the CONNECT tunnel and sends the request out to the internet. Expect HTTP 200 and JSON containing a `current` object, including `temperature_2m`. Do not enable shell tracing (`set -x`) while entering or using the token.

   Traffic path: `curl on workstation -> 127.0.0.1:8088 -> SSM port forwarding -> EC2 proxy in AWS -> HTTPS api.open-meteo.com`.

The workstation runs only curl and the SSM port-forwarding client; the deployed AWS instance is the forward proxy and makes the outbound connection to the external API. For HTTPS, the proxy authorizes the CONNECT destination hostname and then tunnels TLS unchanged. It cannot inspect or authorize the API path, HTTP method, query, or response body; use a direct API/MCP gateway when you need operation-level policy or approval.

To confirm the hostname scope, repeat the request with `https://example.com/` using the same token; because `example.com` was not delegated, the CONNECT should be denied with HTTP 403. A curl tunnel error is expected for that negative test; check that it reports a 403 rather than treating any connection failure as a policy denial. The simpler `make aws-demo DEMO=proxy` probe is a separate plain-HTTP test for `example.com` and needs a delegation for tool `egress`, resource `example.com`, action `read`.

## Delete when finished

```bash
make aws-proxy-delete
```

This waits for stack deletion and removes the proxy instance, encrypted root disk and owned network resources. Shared application/data/image resources remain. Delete the proxy before parent teardown. Closing the SSM tunnel does **not** stop EC2, EBS or public IPv4 charges. Single-instance proxy provisioning does not create an OpenClaw VM or host other demo backends.

CONNECT authorizes the destination at tunnel creation; it does not inspect operations within TLS or terminate existing tunnels when a delegation is revoked. Use direct API/MCP for per-method/body approval.

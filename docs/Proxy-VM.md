# Optional AWS forward-proxy VM

**Skip this for Weather, Geocoding, Users, Refunds and Emotion.** Their direct API/MCP gateways use Lambda. Create this separate VM only for forward-proxy/HTTPS CONNECT or long-lived connection demonstrations you deliberately choose to run.

## Prerequisites

Complete parent deployment using the [customer guide](Deployment-Guide.md). Use this runtime checkout; no private source checkout is needed. Install the AWS Session Manager plugin locally for port forwarding. Set `AWS_VM_PROFILE` in ignored `aws-config.mk` to an explicitly reviewed non-root profile with the EC2, VPC, IAM role/profile, CloudFormation and SSM permissions needed by `deploy/aws/proxy-vm.template.json`. The bounded application role does not automatically have those privileges.

The create script reads the parent's DemoConfiguration, checks the same account, and uses its exact gateway image, activation references, authorization API and DynamoDB tables. Its instance role is scoped to the required shared resources and SSM. Secrets are fetched at boot and are not embedded in user data.

## Preview, create and connect

```bash
make aws-proxy-plan   # offline preview using clearly fake example identifiers
# Deliberate billable operation; only if you want this VM:
make aws-proxy-create
make aws-proxy-status
make aws-proxy-connect
```

The plan is an example parameter preview, not an AWS lookup or an executable plan for your live account. Create obtains live identifiers from the selected parent. Keep connect's terminal open: it provides `http://127.0.0.1:8088` on your workstation through SSM. No security-group ingress/SSH/public proxy port is opened. Use the [proxy demo probe](AWS-Demos.md) with its own egress delegation token.

The default is one `t4g.small` ARM64 instance, standard CPU credits and a 12 GiB encrypted gp3 root disk deleted on termination. `PROXY_INSTANCE_TYPE=t4g.medium` is available. The VM owns a small VPC/public subnet/internet route and uses a public IPv4 address for outbound access. No NAT gateway, load balancer or Auto Scaling group is created. It has **single-instance, single-AZ availability**, with only systemd process restart; active connections are lost on host failure/restart.

## Tutorial: call a real HTTPS API through the proxy

This example calls the public [Open-Meteo forecast API](https://open-meteo.com/) over HTTPS. It needs no upstream API key; the Agent Gateway egress token is still required.

1. In `aws-config.mk`, set `AWS_PROFILE` to a profile that can read the parent stack and `AWS_VM_PROFILE` to an explicitly reviewed, non-root profile allowed to create the proxy stack. Set `AWS_REGION` and `AWS_STACK` to the same region and parent stack used for the deployment. The VM profile must be in the same AWS account as the parent.
2. Review the offline example, then deliberately create and check the VM:

   ```bash
   make aws-proxy-plan
   make aws-proxy-create
   make aws-proxy-status
   ```

   `aws-proxy-create` waits for CloudFormation to finish. Do not continue unless the stack is ready and reports an instance ID.
3. In a separate terminal, open the SSM tunnel and leave it running:

   ```bash
   make aws-proxy-connect
   ```

   The local proxy URL is `http://127.0.0.1:8088` (or the configured `PROXY_LOCAL_PORT`).
4. In the signed-in Agent Gateway Console, create an egress delegation scoped to tool `egress`, resource `api.open-meteo.com`, and action `connect`; mint an agent token for that delegation. The resource is the hostname only: do not include `https://`, a path, or a query string. Use a policy that allows this connection for the test.
5. In another terminal, enter the token without putting it in shell history or curl's command-line arguments, then make the HTTPS request through the SSM tunnel:

   ```bash
   read -r -s -p 'Proxy delegation token: ' PROXY_TOKEN
   printf '\n'
   printf 'proxy = "http://127.0.0.1:8088"\nproxy-header = "Proxy-Authorization: Bearer %s"\n' "$PROXY_TOKEN" |
     curl -q --config - --noproxy '' --fail-with-body --silent --show-error \
       --write-out '\nHTTP %{http_code}\n' \
       'https://api.open-meteo.com/v1/forecast?latitude=51.5072&longitude=-0.1276&current=temperature_2m'
   unset PROXY_TOKEN
   ```

   Expect HTTP 200 and JSON containing a `current` object, including `temperature_2m`. Do not enable shell tracing (`set -x`) while entering or using the token.

This proves the HTTPS request reached the external API through the local SSM tunnel and proxy. For HTTPS, the proxy authorizes the CONNECT destination hostname and then tunnels TLS unchanged. It cannot inspect or authorize the API path, HTTP method, query, or response body; use a direct API/MCP gateway when you need operation-level policy or approval.

To confirm the hostname scope, repeat the request with `https://example.com/` using the same token; because `example.com` was not delegated, the CONNECT should be denied with HTTP 403. A curl tunnel error is expected for that negative test; check that it reports a 403 rather than treating any connection failure as a policy denial. The simpler `make aws-demo DEMO=proxy` probe is a separate plain-HTTP test for `example.com` and needs a delegation for tool `egress`, resource `example.com`, action `read`.

## Delete when finished

```bash
make aws-proxy-delete
```

This waits for stack deletion and removes the proxy instance, encrypted root disk and owned network resources. Shared application/data/image resources remain. Delete the proxy before parent teardown. Closing the SSM tunnel does **not** stop EC2, EBS or public IPv4 charges. Single-instance proxy provisioning does not create an OpenClaw VM or host other demo backends.

CONNECT authorizes the destination at tunnel creation; it does not inspect operations within TLS or terminate existing tunnels when a delegation is revoked. Use direct API/MCP for per-method/body approval.

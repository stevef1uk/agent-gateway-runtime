# Optional AWS forward-proxy VM

**Skip this for Weather, Geocoding, Users, Refunds and Emotion.** Their direct API/MCP gateways use Lambda. Create this separate VM only for forward-proxy/HTTPS CONNECT or long-lived connection demonstrations you deliberately choose to run.

## Prerequisites

Complete parent deployment using the [customer guide](Deployment-Guide.md). Use this runtime checkout; no private source checkout is needed. Install the AWS Session Manager plugin locally for port forwarding.

The proxy VM is optional and requires an explicitly configured `AWS_VM_PROFILE`. This may be the same profile as `AWS_PROFILE`, but only if that non-root identity is approved and allowed to create the resources in `deploy/aws/proxy-vm.template.json`. In ignored `aws-config.mk`, set:

```make
AWS_PROFILE = agent-gateway-dev
AWS_VM_PROFILE = your-approved-vm-profile
```

The VM profile needs CloudFormation and EC2/VPC permissions, permission to create the template's IAM role and instance profile and pass the role to EC2, and SSM permissions to open and close a session. The bounded application role does not automatically have those privileges. Do not assume that `AWS_PROFILE` or an administrator profile is suitable; ask your AWS administrator which profile is approved for these resources.

Before creating anything, verify the VM profile's identity and account:

```bash
aws --profile your-approved-vm-profile --region eu-west-3 sts get-caller-identity
```

Use a non-root identity in the same AWS account as the parent deployment. The create script checks the account, reads the parent's `DemoConfiguration` using `AWS_PROFILE`, and uses its exact gateway image, activation references, authorization API and DynamoDB tables. The instance role is scoped to the required shared resources and SSM. Secrets are fetched at boot and are not embedded in user data.

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

1. In `aws-config.mk`, set `AWS_PROFILE` to a profile that can read the parent stack and `AWS_VM_PROFILE` to the reviewed profile described above. Set `AWS_REGION` and `AWS_STACK` to the same region and parent stack used for the deployment. Check the VM profile with `aws sts get-caller-identity`; it must be non-root and in the same AWS account as the parent. If you do not have a profile with the required permissions, stop here and ask your AWS administrator to provide one.
2. Review the offline example, then deliberately create and check the VM:

   ```bash
   make aws-proxy-plan
   make aws-proxy-create
   make aws-proxy-status
   ```

   `aws-proxy-create` waits for CloudFormation to finish. Do not continue unless the stack is ready and reports an instance ID.
3. From your workstation, in a separate terminal, open the SSM tunnel and leave it running:

   ```bash
   make aws-proxy-connect
   ```

   `127.0.0.1:8088` is only the private entry point on your workstation. SSM forwards that connection to port 8088 on the **EC2 proxy deployed in AWS**; it does not run the proxy or contact Open-Meteo on your workstation.
4. In the signed-in Agent Gateway Console, create an egress delegation scoped to tool `egress`, resource `api.open-meteo.com`, and action `connect`; mint an agent token for that delegation. The resource is the hostname only: do not include `https://`, a path, or a query string. Use a policy that allows this connection for the test.
5. In another workstation terminal, enter the token without putting it in shell history or curl's command-line arguments, then send the HTTPS request through the SSM tunnel:

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

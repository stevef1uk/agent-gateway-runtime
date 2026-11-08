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

## Delete when finished

```bash
make aws-proxy-delete
```

This waits for stack deletion and removes the proxy instance, encrypted root disk and owned network resources. Shared application/data/image resources remain. Delete the proxy before parent teardown. Closing the SSM tunnel does **not** stop EC2, EBS or public IPv4 charges. Single-instance proxy provisioning does not create an OpenClaw VM or host other demo backends.

CONNECT authorizes the destination at tunnel creation; it does not inspect operations within TLS or terminate existing tunnels when a delegation is revoked. Use direct API/MCP for per-method/body approval.

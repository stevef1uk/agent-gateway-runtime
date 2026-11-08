# AWS operator deployment guide

Use the source repository's [repeatable Make workflow](https://github.com/stevef1uk/agent-gateway/blob/aws/docs/aws/make-workflow.md) to validate locally, build/publish reviewed images, apply bounded access and deploy the application. It uses the `agent-gateway-dev` profile by default and Paris (`eu-west-3`); override for the target customer environment. Do not infer endpoints from an older deployment: read CloudFormation outputs.

The [architecture](Architecture.md) describes the single-region serverless control plane, dedicated per-demo gateways, real private Emotion Lambda and optional single-instance proxy. [AWS demos](AWS-Demos.md) lists every runner and whether the proxy must be started first.

The optional proxy is an explicit billable create operation. It is not started by deploying an API/MCP demo or by running a client probe. Its create/connect/status/delete Make wrappers invoke the adjacent source checkout (`AGW_SOURCE_DIR`, default `../agent-gateway`). A separately reviewed non-root `AWS_VM_PROFILE` must have the necessary EC2/IAM/CloudFormation/SSM permissions.

Delete the optional proxy before tearing down parent/shared resources. Application cleanup retains data unless explicitly purged; deleting images and administrator access is separate. See the source [teardown guide](https://github.com/stevef1uk/agent-gateway/blob/aws/docs/aws/teardown.md).

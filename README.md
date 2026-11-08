# Agent Gateway AWS runtime demos

This `aws` branch contains customer-facing clients for the single-region Lambda deployment and its optional EC2 forward proxy.

* [Demo commands and proxy prerequisites](docs/AWS-Demos.md): weather, geocoding, users, refunds simulation, Emotion and forward-proxy probes.
* [Customer-managed OpenClaw and advanced demo hosts](docs/Customer-Managed-Demos.md).
* [Selected architecture and availability limits](docs/Architecture.md).
* [Baseline weather approval tutorial](docs/Public-API-Curl-Tutorial.md).
* [Operator deployment guide](docs/Deployment-Guide.md).

## Quick start

Deploy the parent and selected demo with the [source Make workflow](https://github.com/stevef1uk/agent-gateway/blob/aws/docs/aws/make-workflow.md), or use the signed-in AI Wizard. Copy the selected child demo's GatewayURL and create a matching delegation. The runner prompts privately for its token.

```bash
make check
export GATEWAY_URL='https://REPLACE.execute-api.eu-west-3.amazonaws.com'
make aws-demo DEMO=users
make aws-demo DEMO=emotion PHASE=held
# Approve in the console, then:
make aws-demo DEMO=emotion PHASE=approved
```

API/MCP demos do not need the proxy VM. Forward-proxy clients need `make aws-proxy-create AWS_VM_PROFILE=NAME` followed by `make aws-proxy-connect AWS_VM_PROFILE=NAME`; keep the tunnel open. Use `make aws-proxy-delete AWS_VM_PROFILE=NAME` when finished to remove billable proxy resources. The application backend and OAuth credentials for Gmail/custom services are separate prerequisites.

`make demo` and `bash demo/run-aws-weather-demo.sh` retain the baseline weather workflow. Use the parent's GatewayURL for these unprefixed `/v1/...` requests. The browser runner requires Playwright and Cognito sign-in; it does not provision AWS resources.

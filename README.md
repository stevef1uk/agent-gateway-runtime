# Agent Gateway AWS runtime demos

This `aws` branch contains customer-facing clients for the single-region Lambda deployment and its optional EC2 forward proxy.

* [Demo commands and proxy prerequisites](docs/AWS-Demos.md): weather, geocoding, users, refunds simulation, Emotion and forward-proxy probes.
* [Customer-managed OpenClaw and advanced demo hosts](docs/Customer-Managed-Demos.md).
* [Selected architecture and availability limits](docs/Architecture.md).
* [Baseline weather approval tutorial](docs/Public-API-Curl-Tutorial.md).
* [Operator deployment guide](docs/Deployment-Guide.md).

## Quick start

Deploy the parent and selected demo with the [source Make workflow](https://github.com/stevef1uk/agent-gateway/blob/aws/docs/aws/make-workflow.md), or use the signed-in AI Wizard. **These clients require an existing deployment**; they do not deploy AWS resources. Start with the [full setup and endpoint instructions](docs/AWS-Demos.md).

From this **agent-gateway-runtime** checkout on branch `aws`, check the clients and retrieve the complete Users demo URL:

```bash
make check
make -s aws-demo-url DEMO=users
export GATEWAY_URL="$(make -s aws-demo-url DEMO=users)"
unset AGENT_TOKEN
make aws-demo DEMO=users
```

`aws-demo-url` reads the child stack's `GatewayURL` using AWS CLI profile `agent-gateway-dev` in `eu-west-3`. It prints the actual HTTPS URL, so no API ID needs to be guessed or replaced. If the stack does not exist, deploy the Users demo first. The runner prompts privately for the token from the **Users delegation** created in your signed-in console. This token is distinct from your AWS credentials and Cognito login token.

Emotion has its **own gateway URL and delegation token**. Deploy Emotion and configure a delegation that allows `emotion_detection` and requires human approval for `emotion_detection_detailed`, then switch to it:

```bash
export GATEWAY_URL="$(make -s aws-demo-url DEMO=emotion)"
unset AGENT_TOKEN
make aws-demo DEMO=emotion PHASE=access
make aws-demo DEMO=emotion PHASE=held
# In the console, approve the exact approval ID printed by the held command.
make aws-demo DEMO=emotion PHASE=approved
```

Enter the **same Emotion delegation token** at each prompt. A native Emotion licence error is a valid result after authorization; it is not evidence that inference succeeded. If the token expires, mint a fresh token for the same delegation. The [full guide](docs/AWS-Demos.md) explains custom stack/profile settings and CloudFormation console lookup.

API/MCP demos do not need the proxy VM. Forward-proxy clients need `make aws-proxy-create AWS_VM_PROFILE=NAME` followed by `make aws-proxy-connect AWS_VM_PROFILE=NAME`; keep the tunnel open. Use `make aws-proxy-delete AWS_VM_PROFILE=NAME` when finished to remove billable proxy resources. The application backend and OAuth credentials for Gmail/custom services are separate prerequisites.

`make demo` and `bash demo/run-aws-weather-demo.sh` retain the baseline weather workflow. Use the parent's GatewayURL for these unprefixed `/v1/...` requests. The browser runner requires Playwright and Cognito sign-in; it does not provision AWS resources.

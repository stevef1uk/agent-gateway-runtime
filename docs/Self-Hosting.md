# Self-hosting on AWS

The `aws` branch contains the public CloudFormation templates, Make deployment commands and AWS CLI/Python lifecycle scripts. It consumes published encrypted `_l` Docker Hub images and a prebuilt Emotion Lambda wrapper; it does not contain proprietary application source or require customers to build it.

Follow [Deploy Agent Gateway to your AWS account](Deployment-Guide.md) from step 1. The guide explains current release/activation prerequisites, the administrator's existing-role setup, local configuration, billable deployment, invitations, real endpoint discovery and cleanup.

The supported scripted region is Paris (`eu-west-3`). You need a compatible current release manifest and customer activation material from the vendor. The historical four-image release does not support the full updated Wizard; use `make aws-release-check` before proceeding.

## Optional forward proxy

The public repository also includes the optional single-instance [proxy VM lifecycle](Proxy-VM.md). It is separate from the default Lambda deployment and is unnecessary for the five API/MCP demo presets. Customer-managed OpenClaw/backend hosts remain outside supplied provisioning: see [advanced demo hosts](Customer-Managed-Demos.md).

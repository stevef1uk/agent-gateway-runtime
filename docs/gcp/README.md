# GCP documentation

These documents describe the published-image customer deployment in this repository:

- [Deployment guide](../GCP-Deployment-Guide.md): project prerequisites, deployment, verification, and teardown.
- [Console tutorial](../GCP-Console-Tutorial.md): creating delegations, choosing Rego, editing policy, and restoring versions.
- [Demo guide](../GCP-Demos.md): configured API/MCP demos, the live weather walkthrough, and compatibility with the numbered `main` demos.
- [Custom API and MCP walkthrough](local-custom-upstream-wizard-test.md): register an existing upstream, create a scoped delegation, and test the governed route.
- [Customer-managed integrations](customer-managed-demos.md): limits and responsibilities for OpenClaw/OpenShell, CRM, Gmail, and other external services.
- [Architecture](architecture.md): Cloud Run services, authentication, storage, licensing, and optional Emotion backend.
- [Pricing estimate](serverless-pricing.md): indicative costs and the assumptions used.

The separate [`agent-gateway` source repository](https://github.com/stevef1uk/agent-gateway/tree/gcp/docs/gcp) contains developer-focused Terraform and source-build documentation. Its Terraform deployment workflow is not used by this runtime repository's customer deploy script.

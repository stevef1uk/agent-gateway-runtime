# Agent Gateway — AWS deployment

The **`aws` branch** deploys Agent Gateway into your own AWS account using published plain-binary **`_l` images with signed licence verification from Docker Hub**. Application source and a Go compiler are not required. The `main` branch contains the separate local/container demos.

Start with the **[customer deployment and testing guide](docs/Deployment-Guide.md)**. It explains prerequisites, activation files, configuration, administrator setup, Make deployment, sign-in and your first demo.

* [AWS architecture and availability limits](docs/Architecture.md)
* [Demo commands and proxy prerequisites](docs/AWS-Demos.md)
* [Optional proxy VM and cleanup](docs/Proxy-VM.md)
* [Customer-managed OpenClaw and advanced demos](docs/Customer-Managed-Demos.md)
* [Teardown and retained data](docs/Teardown.md)

```bash
git clone --branch aws https://github.com/stevef1uk/agent-gateway-runtime.git
cd agent-gateway-runtime
make check
```

`make check` is offline and creates no AWS resources. Deployment requires a current vendor release manifest and compatible activation material; historical manifests are not substitutes. The [guide](docs/Deployment-Guide.md#3-obtain-the-current-release-and-activation-files) explains these inputs before any billable deployment. OpenClaw hosts are not created by this repository; the proxy VM is optional.

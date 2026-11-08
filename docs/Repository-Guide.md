# What this aws branch contains

This public repository provides customer deployment and demo clients for prebuilt Agent Gateway images. It contains no proprietary application source and requires no Go compiler.

| Path | Purpose |
|---|---|
| `Makefile`, `aws-config.example.mk` | Public customer deployment, lookup, test and cleanup commands; local ignored configuration |
| `deploy/aws/` | Reviewed CloudFormation activation/access/application/proxy templates and validation rules |
| `scripts/deploy-aws.sh`, `scripts/aws-release.py` | Validate a current vendor manifest, import Docker Hub images to private ECR, deploy and save outputs/inventory |
| `scripts/teardown-aws-deployment.py`, `scripts/aws-demo-stacks.py` | Account/ownership-checked cleanup and owned-demo inspection |
| `scripts/aws-proxy-vm.py` | Explicit optional proxy lifecycle; never creates OpenClaw/backend hosts |
| `demo/aws-demo.py` | REST/MCP/HTTP proxy client phases |
| `demo/public-weather-tutorial.sh` | Baseline weather allow/approval/revocation client |
| `docs/Deployment-Guide.md` | Customer starting point |
| `docs/Customer-Managed-Demos.md` | Customer-owned advanced host prerequisites |

Vendor image builds and source-level tests stay in the private source repository. Customers receive published `_l` images, the prebuilt Emotion wrapper, a compatible release manifest and activation material. A current manifest is required; historical recorded releases are not promoted automatically.

`make check` is offline. `make aws-demo-url` reads a deployed child's URL. `make aws-deploy` explicitly creates billable application resources, and `make aws-proxy-create` separately opts into a billable VM. The main branch retains its different local Compose/Dex/sandbox workflows.

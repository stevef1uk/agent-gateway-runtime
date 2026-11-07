# What the runtime `aws` branch contains

This branch starts with **one** scenario: Cognito-authenticated human delegation
and curl probes against the public weather API through your AWS gateway.

| Path | Purpose |
| --- | --- |
| `README.md` | Entry point and current implementation/deployment status |
| `docs/Public-API-Curl-Tutorial.md` | AWS-specific human/agent walkthrough |
| `demo/weather-delegation.json` | Non-secret scoped delegation payload |
| `demo/public-weather-tutorial.sh` | Three manual client phases: access, approved, revoked |
| `docs/AWS-Marketplace.md` | Planned Marketplace procurement/fulfillment and explicit availability status |
| `docs/Self-Hosting.md` | Separate customer self-hosting prerequisites/release status |
| `docs/Deployment-Guide.md` | Source release/settings and operator provisioning links |
| `docs/Architecture.md` | Trust boundaries and limitations |
| `docs/Pricing.md` | Source cost model and provider/budget scope |
| `docs/Teardown.md` | Source cleanup commands and retained-data warning |
| `scripts/test_weather_client.py` | Offline fake-curl tests; no network/AWS calls |
| `SECURITY.md`, `LICENSE` | Credential guidance and repository licence |

The old Compose/Dex/image keys, Kubernetes manifests, unrelated tutorials,
recorded scans and live-demo advertising have been removed from this branch's
working tree. The `main` branch retains its separate history and local demos.
They are not AWS instructions. There are no unattended human approvals, embedded
credentials or automatic deployments in the AWS weather client.

Hosted-demo users need only their operator's URLs/invitation. A customer
self-hosting release bundle is still pending publication; the internal evaluation
operator currently provisions from an authorized source checkout. This branch does not copy proprietary implementation code into a demo
repository, provide a Marketplace installer or assert that every previous demo is
ported. Subsequent AWS scenarios can be added after their code and real acceptance
behavior are established.

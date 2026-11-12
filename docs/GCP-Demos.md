# Agent Gateway demos on GCP

This guide covers the demos available in the published-image GCP deployment
from this repository's `gcp` branch. It is not a guide to the source-build or
Terraform workflow in the separate `agent-gateway` repository.

The GCP deployment uses a public Cloud Run web service for the Console and
agent-facing proxy, and a private Cloud Run Gateway for policy enforcement.
Agents and demo clients use the **web Console URL**; do not give them the
private Gateway URL or call an upstream directly if you want the request
governed.

## What the deployment provides

The deploy script configures these upstream routes:

| Demo | Governed path | Upstream | Notes |
|---|---|---|---|
| Weather | `/v1/forecast`, `/v1/elevation` | Open-Meteo weather API | Elevation approval is demonstrated by the live tutorial below. |
| Geocoding | `/api-geocoding/v1/search` | Open-Meteo Geocoding API | Search requests; create a read-only delegation for this path. |
| Users | `/api-users/users...` | JSONPlaceholder | Example REST API; writes are simulated and are not persistent. |
| Refunds | `/api-refunds/posts...` | JSONPlaceholder | A refund-themed simulation only. It does not issue refunds or persist writes. |
| Emotion MCP | `/mcp-emotion` | Optional private Emotion Cloud Run service | Deploy with `--emotion`. The bundled evaluation licence is used unless a separate vendor-issued Emotion token is supplied. |

These are configured routes, not independently deployed demo stacks. The GCP
API Wizard also registers existing reachable HTTP(S) APIs and MCP servers and
creates scoped delegations for them; it does not deploy those services.
Follow the [custom-upstream walkthrough](gcp/local-custom-upstream-wizard-test.md)
to register and test one. Built-in demo routes are deployment-configured and
do not have the customer-registered upstream Delete action.

## Create and test a delegation

1. Sign in to the GCP Console using an account in the deployment's
   `--admin-emails` allowlist, then open **API Wizard**.
2. Select the configured API or MCP service. Scope the delegation to the
   specific path and actions the agent needs. For example, use `read` for
   weather forecast or geocoding, and do not grant writes for a read-only
   walkthrough.
3. If demonstrating human approval, add an approval rule to the relevant
   operation. Approval is a Console workflow; it is not an upstream API
   feature.
4. Create the delegation and retain its ID and agent secret securely. Use the
   Wizard's **Token** tab to mint a short-lived access token.
5. Use the Console's API tester with that delegation and token to test other
   configured routes. Example paths include:
   - `GET /api-geocoding/v1/search?name=Berlin&count=5&language=en&format=json`
   - `GET /api-users/users/1`
   - `GET /api-refunds/posts`
   - MCP `tools/list` or an allowed tool call at `/mcp-emotion` when Emotion is
     deployed.

The tester and the live weather script below send requests through the public
Console service to the private Gateway. Never put the agent secret or access
token in a URL, source control, or shared logs.

## Run the weather approval walkthrough

The runtime repository includes a live script that checks authentication,
scope denial, method denial, approval, single-use approval, and revocation.
Create a delegation scoped to `/v1/forecast` and `/v1/elevation` with `read`
access and an approval rule for `read` on `/v1/elevation`, as described in the
[deployment guide](GCP-Deployment-Guide.md).

Run the `access` phase from the runtime repository root, using the public web
Console Cloud Run URL printed by the deployment script:

```bash
CONSOLE_URL="https://WEB_CLOUD_RUN_HOST" \
  bash demo/public-weather-tutorial-gcp.sh access
```

The script prompts privately for the access token if `AGENT_TOKEN` is unset.
It expects forecast access to succeed, an unauthenticated request and
out-of-scope requests to be denied, and elevation to be held with HTTP 202.
Approve that elevation request in the signed-in Console, then run:

```bash
CONSOLE_URL="https://WEB_CLOUD_RUN_HOST" \
  bash demo/public-weather-tutorial-gcp.sh approved
```

This phase checks that the approved elevation call succeeds once and that the
next call is held again. Revoke the delegation in the Console, then run the
last phase before the token expires:

```bash
CONSOLE_URL="https://WEB_CLOUD_RUN_HOST" \
  bash demo/public-weather-tutorial-gcp.sh revoked
```

The script never approves or revokes on your behalf. Review its output and the
Console audit trail. It requires `bash`, `curl`, and `python3`, and creates no
cloud resources.

## Mapping the numbered `main` demos to GCP

This matrix describes the GCP published-image deployment. It does not claim
that local `main` branch scripts, fixtures, or assumptions work unchanged on
GCP.

| Main demo | GCP availability |
|---|---|
| 1. Scripted purchasing | Not provided end to end. There is no purchasing backend; the refunds route is a JSONPlaceholder simulation, not a payment or refund service. |
| 2. Graphical walkthrough | Partially covered by the GCP Console: create delegations, review approvals, and inspect audit activity. Main-branch local fixtures and UI are separate. |
| 3. OPA playground | Supported by the administrator-only Rego editor, per-delegation policy-engine selection, version history, and decision probes. See the [GCP Console tutorial](GCP-Console-Tutorial.md). |
| 4. Protected API | Supported for the configured demo routes and customer-registered reachable APIs through the public Console endpoint. These are not per-demo Lambda or Cloud Run stacks. |
| 5. Outbound egress | Not provided. The GCP deployment has no general HTTP forward proxy. |
| 6. OpenClaw/OpenShell sandbox | Customer-managed and separate. A sandbox can use an explicitly configured supported Gateway API/MCP route, but the GCP deployment does not install or govern all sandbox egress. |
| 7. Sandbox egress rules | Not provided as a Gateway-backed generic egress demo; there is no GCP forward-proxy service in this deployment. |
| 8. Invoice/prompt injection and human delegation | Not provided end to end. It requires a separately hosted invoice/payment backend and an agent integration; the refunds simulation is not that backend. |
| 9. MCP/CRM | Emotion MCP is available when deployed with `--emotion`; an existing reachable MCP server can also be registered. No CRM MCP backend is provisioned. |
| 10. DPoP/RAR | No GCP end-to-end walkthrough is provided in this repository. Do not treat the Bearer-token weather script as a DPoP/RAR test. |
| 11. Kill switch | Delegation revocation is supported and the weather walkthrough verifies subsequent calls are denied. Revocation does not cancel an in-flight request. |
| 12. Approval edge cases | The weather walkthrough covers a basic held/approved/single-use flow. It is not a complete reproduction of the local test harness's concurrency and replay edge cases. |
| 13. Public weather | Supported by the weather walkthrough above. |
| 14. Gmail approvals | Not provided. A Gmail connector, OAuth consent/credentials, state, and client integration would need to be supplied and operated separately. |

For OpenClaw/OpenShell, CRM, Gmail, or other customer-hosted systems, see
[customer-managed integrations](gcp/customer-managed-demos.md).

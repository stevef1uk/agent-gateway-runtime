# Agent Gateway — AWS Serverless Edition (`aws` branch)

> Recovery status (8 November 2026): console build **1.0.93** is repaired in source and still requires a new encrypted image release and live acceptance testing. Endpoint identifiers below are recorded deployment values; confirm current CloudFormation outputs before using them.

Give an AI agent least-privilege read access to weather data (`/v1/forecast`), hold sensitive lookups (`/v1/elevation`) for a single-use human approval, block out-of-scope paths (`/v1/marine`) and write methods (`POST`), and revoke access immediately while the agent's JWT is still valid.

This **`aws` branch** accompanies the **Agent Gateway AWS Serverless Edition** deployed in **Paris (`eu-west-3`)**.

---

## Live AWS Serverless Deployment (`eu-west-3`)

| Component | Endpoint / Identifier | Role |
|---|---|---|
| **Web Console (`ConsoleURL`)** | `https://0b7565mq7j.execute-api.eu-west-3.amazonaws.com` | Cognito PKCE OIDC sign-in, Delegation Wizard, AI Config Assistant (Amazon Bedrock), Pending Approvals, Interactive Endpoint Tester, and Audit Trail |
| **Public PEP Gateway (`GatewayURL`)** | `https://p2ye0fbw36.execute-api.eu-west-3.amazonaws.com` | Public agent ingress enforcing Bearer/DPoP tokens, delegation scope, single-use human approvals, and immediate DynamoDB revocation |
| **Governed Upstream** | `https://api.open-meteo.com` | Open-Meteo Forecast (`/v1/forecast`) and Elevation (`/v1/elevation`) REST APIs |
| **Cognito User Pool** | `eu-west-3_8YUGYY8ao` | Hosted UI domain `https://agw-weather-857710215813.auth.eu-west-3.amazoncognito.com` |

---

## 3 Ways to Run the Demo

### Option 1: Interactive Web Console (Zero CLI / Zero DevTools Needed)

1. Open the **Web Console**: `https://0b7565mq7j.execute-api.eu-west-3.amazonaws.com` and click **Sign in with Cognito**.
2. Click **`🌤️ Quick Weather Delegation`** (or use **`🧙 Delegation Wizard`** / **`✨ AI Config Assistant (Bedrock)`** to create multiple custom delegations).
   - This creates a scoped delegation (`read` on `/v1/forecast` and `/v1/elevation`, with `/v1/elevation` requiring human approval) and loads a live short-lived Bearer JWT directly into the **Interactive Endpoint Tester**.
3. In the **Interactive Endpoint Tester**, click the scenario buttons and **▶ Send Test Request Now**:
   - **`🌤️ Forecast GET (200 Allowed)`** -> Returns **`HTTP 200 OK`** with live London weather JSON.
   - **`⛰️ Elevation GET (202 Held)`** -> Returns **`HTTP 202 Accepted — HELD FOR HUMAN APPROVAL`**.
   - Approve the held request in the **Pending approvals** panel at the top of the page, then click **▶ Send Test Request Now** again -> Returns **`HTTP 200 OK`** once (subsequent calls return **`202`** again).
   - **`🌊 Marine Path (403 Out of Scope)`** -> Returns **`HTTP 403 Forbidden`**.
   - **`🚫 Forecast POST (403 Read-Only)`** -> Returns **`HTTP 403 Forbidden`**.
   - **`🚫 No Token (401)`** -> Returns **`HTTP 401 Unauthorized`**.

### Option 2: Automated Playwright + CLI Runner (One Command)

Run the entire 3-phase verification (`access`, `approved`, `revoked`) automatically without copying or pasting tokens:

```sh
bash demo/run-aws-weather-demo.sh
```

- Launches Chrome via Playwright (`scripts/playwright_weather_demo.js`) using a persistent profile (`/tmp/agw-weather-playwright-profile`) so you only sign in to Cognito once.
- Creates the `aws-weather-test` delegation in the Console, runs all 6 `access` probes, approves the held elevation request in the Console, verifies single-use `200` consumption and `202` replay hold, revokes the delegation in the Console while the token is still valid, and proves immediate `403` revocation enforcement.

### Option 3: Step-by-Step cURL / Bash Probes

```sh
export GATEWAY_URL='https://p2ye0fbw36.execute-api.eu-west-3.amazonaws.com'
read -r -s -p 'Agent token: ' AGENT_TOKEN; printf '\n'
export AGENT_TOKEN

# Phase 1: 401 no-token, 200 forecast, 403 POST, 403 /v1/marine, 403 forged header, 202 elevation hold
bash demo/public-weather-tutorial.sh access

# Phase 2: After approving the pending request in the Console:
bash demo/public-weather-tutorial.sh approved

# Phase 3: After revoking the delegation in the Console (while token is still unexpired):
bash demo/public-weather-tutorial.sh revoked
unset AGENT_TOKEN GATEWAY_URL
```

---

## Expected Outcomes

| Probe | Expected Result |
|---|---|
| Forecast `GET /v1/forecast` without token | `401 Unauthorized` |
| Forecast `GET /v1/forecast` with delegated token | `200 OK` with real Open-Meteo temperature & wind JSON |
| Forecast `POST /v1/forecast` with read-only delegation | `403 Forbidden` |
| Out-of-scope `GET /v1/marine` | `403 Forbidden` |
| `POST /v1/forecast` with forged `X-Agent-Action: read` | `403 Forbidden` (actual HTTP method governs policy) |
| Elevation `GET /v1/elevation` before human consent | `202 Accepted` + `approval_id` (upstream is not called) |
| Elevation `GET /v1/elevation` after human approval | `200 OK` once; next identical request returns `202 Accepted` |
| Forecast `GET /v1/forecast` after delegation revocation | `403 Forbidden` immediately across all Lambda workers |

---

## Documentation Index

- **[AWS Serverless Architecture & Components](docs/Architecture.md)** — Full diagram and breakdown of the 3 CloudFormation stacks, 4 encrypted ARM64 Lambda functions, 5 HTTP APIs (`WebAPI`, `GatewayAPI`, `AuthzAPI`, `TokensvcAPI`, `GatewayInternalAPI`), SigV4 internal identity envelope, DynamoDB tables, Cognito PKCE OIDC, S3 activation, and Amazon Bedrock integration.
- **[Operator Deployment Guide](docs/Deployment-Guide.md)** — How the AWS Serverless stack is deployed and updated using `scripts/deploy-aws-weather-demo.sh` and `serverless-images.template.json`.
- **[Weather Walkthrough & Troubleshooting](docs/Public-API-Curl-Tutorial.md)** — Detailed Console, Playwright, and CLI walkthrough.
- **[Self-Hosting on AWS](docs/Self-Hosting.md)** — Requirements and deployment flow for customer-owned AWS accounts.
- **[Paris Serverless Cost Model](docs/Pricing.md)** & **[Teardown Guide](docs/Teardown.md)**.

[Weather data by Open-Meteo.com](https://open-meteo.com/). See [LICENSE](LICENSE) and [SECURITY.md](SECURITY.md).

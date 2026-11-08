# AWS Weather Demo Walkthrough: Console, Playwright & cURL

Endpoint examples use placeholders: replace them with your CloudFormation `ConsoleURL` and `GatewayURL` outputs.


This walkthrough demonstrates the **Agent Gateway AWS Serverless Edition** governing access to `https://api.open-meteo.com` through the live stack in **Paris (`eu-west-3`)**:

- **ConsoleURL (`WebAPI`)**: `https://CONSOLE_API_ID.execute-api.eu-west-3.amazonaws.com`
- **GatewayURL (`GatewayAPI`)**: `https://GATEWAY_API_ID.execute-api.eu-west-3.amazonaws.com`

You do **not** need to open Chrome DevTools or paste JavaScript snippets. Choose any of the three workflows below.

---

## Workflow 1: Interactive Web Console (Recommended First Test)

1. **Sign In via Cognito**:
   - Open `https://CONSOLE_API_ID.execute-api.eu-west-3.amazonaws.com` and click **Sign in with Cognito**.
2. **Create One or More Delegations**:
   - Click **`🌤️ Quick Weather Delegation`** in the **Delegations** section to create the `aws-weather-test` delegation (`read` on `/v1/forecast` and `/v1/elevation`, with human approval required for `/v1/elevation`) and load its Bearer token into the **Interactive Endpoint Tester**.
   - **Create additional delegations anytime**:
     - Click **`🧙 Delegation Wizard`** to open the 5-step wizard and create delegations for other agents or resource combinations (e.g. `/v1/forecast` only, or custom spend caps).
     - Click **`✨ AI Config Assistant (Bedrock)`** to generate a delegation from natural language using Amazon Bedrock (`eu.amazon.nova-micro-v1:0`).
     - Or use the **New delegation** form at the bottom of the Console.
     - Click **`▶ Test`** on an active row to select that exact delegation. Paste its existing Bearer token or enter its agent secret to mint a fresh token; testing never revokes or replaces it.
3. **Test Live Requests in the Console's Interactive Endpoint Tester**:
   - Click **`🌤️ Forecast GET (200 Allowed)`** -> **▶ Send Test Request Now** -> Verify **`HTTP 200 OK`** with real London temperature and wind speed JSON.
   - Click **`⛰️ Elevation GET (202 Held)`** -> **▶ Send Test Request Now** -> Verify **`HTTP 202 Accepted — HELD FOR HUMAN APPROVAL`**.
   - Scroll up to **Pending approvals**, click **Approve**, then click **▶ Send Test Request Now** again -> Verify **`HTTP 200 OK`** with `"elevation": [25.0]`. Click **▶ Send Test Request Now** once more -> Verify **`HTTP 202 Accepted`** (single-use approval was consumed).
   - Click **`🌊 Marine Path (403 Out of Scope)`** -> **▶ Send Test Request Now** -> Verify **`HTTP 403 Forbidden`**.
   - Click **`🚫 Forecast POST (403 Read-Only)`** -> **▶ Send Test Request Now** -> Verify **`HTTP 403 Forbidden`**.
   - Click **`🚫 No Token (401)`** -> **▶ Send Test Request Now** -> Verify **`HTTP 401 Unauthorized`**.
4. **Verify the Audit Trail**:
   - Scroll to **Protected API / MCP Audit Trail** to inspect every `ALLOW`, `HELD (202)`, and `DENY` event recorded in DynamoDB.

---

## Workflow 2: Automated End-to-End Playwright + CLI Runner

To run all CLI curl probes (`access`, `approved`, `revoked`) while Playwright handles the browser actions (creating the delegation, approving the held elevation request, and revoking the delegation):

```sh
bash demo/run-aws-weather-demo.sh
```

1. **Step 1 (`create-delegation`)**: Opens Chrome (`scripts/playwright_weather_demo.js`) using a persistent profile `/tmp/agw-weather-playwright-profile`. If you are not signed in yet, sign in via Cognito in the opened Chrome window; Playwright automatically detects the signed-in session, creates the `aws-weather-test` delegation, and captures `AGENT_TOKEN` in memory.
2. **Step 2 (`access` probes)**: Runs `bash demo/public-weather-tutorial.sh access` against `https://GATEWAY_API_ID.execute-api.eu-west-3.amazonaws.com` and captures the held `APPROVAL_ID`:
   - `PASS no-token: HTTP 401`
   - `PASS forecast: HTTP 200`
   - `PASS post-denied: HTTP 403`
   - `PASS marine-denied: HTTP 403`
   - `PASS header-override-ignored: HTTP 403`
   - `PASS elevation-held: HTTP 202, approval_id=...`
3. **Step 3 (`approve` + `approved` probes)**: Playwright approves `APPROVAL_ID` in the Console, then runs `bash demo/public-weather-tutorial.sh approved`:
   - `PASS elevation-approved: HTTP 200`
   - `PASS approval-single-use: HTTP 202`
4. **Step 4 (`revoke` + `revoked` probe)**: Playwright revokes the delegation in the Console while the token is still valid, then runs `bash demo/public-weather-tutorial.sh revoked`:
   - `PASS revoked-token: HTTP 403`

---

## Workflow 3: Manual CLI Probes (`demo/public-weather-tutorial.sh`)

If you want to run the shell probes manually using a Bearer token copied from the Console's Endpoint Tester (`Copy Token` button):

```sh
export GATEWAY_URL='https://GATEWAY_API_ID.execute-api.eu-west-3.amazonaws.com'
read -r -s -p 'Agent token: ' AGENT_TOKEN; printf '\n'
export AGENT_TOKEN

# 1. Run access & hold probes
bash demo/public-weather-tutorial.sh access

# 2. Click "Approve" in the Console's Pending approvals panel, then run:
bash demo/public-weather-tutorial.sh approved

# 3. Click "Revoke" on the delegation in the Console while the token is still valid, then run:
bash demo/public-weather-tutorial.sh revoked

unset AGENT_TOKEN GATEWAY_URL
```

---

## Boundaries & Troubleshooting

- **Offline syntax & unit checks**: Run `make check` to execute `bash -n` and `scripts/test_weather_client.py` with fake-curl fixtures (zero network calls).
- **Unexpected `401 Unauthorized`**: Token missing or expired (default token TTL is 5 minutes; click `⚡ Mint Fresh Bearer Token Now` in the Console Endpoint Tester or re-run `demo/run-aws-weather-demo.sh`).
- **Unexpected `403 Forbidden`**: Verify the delegation covers `/v1/forecast` and `/v1/elevation` with `read` action and has not been revoked.

[Weather data by Open-Meteo.com](https://open-meteo.com/).

## Additional AWS demos and optional proxy

See [AWS demos and proxy prerequisites](AWS-Demos.md). API/MCP Lambda demos do not require the proxy VM; forward-proxy clients require the VM and an open SSM tunnel. Backend/OAuth dependencies are separate. The [source Make workflow](https://github.com/stevef1uk/agent-gateway/blob/aws/docs/aws/make-workflow.md) describes build/deploy/cleanup.

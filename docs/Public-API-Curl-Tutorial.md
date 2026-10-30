# Protect a public weather API — a curl-only tutorial

In about 10 minutes, put **Agent Gateway in front of Open-Meteo**, give an
agent limited access, require a human decision for one endpoint, and revoke
access while its token is still valid. Every API interaction uses `curl`.
No browser, console, SDK, Python, AI model or API key is needed.

**Files:** [runnable script](../demo/public-weather-tutorial.sh) ·
[Compose configuration](../demo/docker-compose.weather.yml).

## What you will protect

[Open-Meteo](https://open-meteo.com/) provides weather forecasts useful for
travel planning, outdoor work and dashboards. We will request London's current
temperature and wind speed, then its elevation. The public endpoints are:

- `https://api.open-meteo.com/v1/forecast`
- `https://api.open-meteo.com/v1/elevation`

The tutorial uses its free non-commercial API. Weather data attribution:
**[Weather data by Open-Meteo.com](https://open-meteo.com/)**. See the provider's
[documentation](https://open-meteo.com/en/docs),
[terms](https://open-meteo.com/en/terms) and
[pricing](https://open-meteo.com/en/pricing) for usage limits and commercial use.

```text
curl (acting as an agent)
  │ Authorization: Bearer <short-lived agent token>
  ▼
Agent Gateway :8087 ──► authorization service :8081
  │                    checks the human's delegation
  ├── deny ──────────► 401 / 403; no upstream request
  ├── hold ──────────► 202 + approval_id; no upstream request
  └── allow ────────► HTTPS api.open-meteo.com ──► real JSON response
```

You are protecting **access through your gateway**. Open-Meteo remains a public
service; this exercise does not change its security or prevent direct calls to
it. For an agent that must use the gateway, restrict its network egress. For
your own private API, make the upstream reachable only from the gateway.

## 1. Start the small tutorial stack

Requirements:

- A checkout of this repository; run the commands below from its root.
- Docker Engine with Docker Compose v2 (`--wait` support), or Podman with a
  compatible Compose provider.
- Bash, `curl`, and `jq` on your machine. `jq` builds and reads JSON; all HTTP
  requests are made with `curl`.
- Internet access from the containers to `api.open-meteo.com:443` and the
  image registries. Ports 5556, 8081, 8082 and 8087 available locally.

```bash
docker compose -f demo/docker-compose.yml -f demo/docker-compose.weather.yml \
  up -d --wait tokensvc gateway-weather
```

This starts only the weather gateway, authorization service, token service,
Dex identity provider, Postgres and Redis. Published images and the bundled
demo licence/keys are used; there is nothing to build. The overlay adds a
dedicated gateway with `UPSTREAM_URL=https://api.open-meteo.com`, published on
loopback port 8087. It uses the same authorization and token services as the
other demos. Requests keep their path and query string when forwarded.

For Podman, substitute `podman compose` for `docker compose` throughout.

### Run the complete script

```bash
bash demo/public-weather-tutorial.sh
```

It pauses before recording Alice's approval. Press Enter to approve or Ctrl-C
to cancel. Complete the approval promptly: agent tokens last five minutes.
For a fully unattended demonstration:

```bash
bash demo/public-weather-tutorial.sh --yes
```

`--yes` **simulates the human decision** using the demo operator credential.
It is not an agent approving itself. The script asserts HTTP statuses and real
weather response fields, checks the audit evidence, and exits nonzero on a
failure. It revokes its delegation on completion or early exit; temporary
response data is removed. Each run creates its own delegation.

Expected highlights:

| Request | Expected result |
|---|---|
| Forecast without a token | **401** |
| Forecast with a delegated agent token | **200**, real weather JSON |
| POST with a read-only delegation | **403** |
| A path outside the delegation | **403** |
| Elevation lookup before approval | **202**, approval ID |
| Operator records Alice's approval | **200**, decision recorded |
| Identical elevation lookup after approval | **200**, elevation JSON |
| Another elevation lookup | **202**, fresh approval needed |
| Forecast after revocation, same token | **403** |
| Operator fetches this delegation's audit | **200**, allow/hold/deny events |

The following sections explain the same flow with commands you can run
individually. They create a separate delegation from the scripted run.

## 2. Set your endpoints and try the public API

Keep using the same Bash session for the walkthrough:

```bash
GW=http://localhost:8087
AUTHZ=http://localhost:8081
TS=http://localhost:8082
DEX=http://localhost:5556
ADMIN_TOKEN=agent-gateway-demo-admin

QUERY='latitude=51.5072&longitude=-0.1276'
FORECAST="$GW/v1/forecast?$QUERY&current=temperature_2m,wind_speed_10m&forecast_days=1"
ELEVATION="$GW/v1/elevation?$QUERY"

curl --fail --silent --show-error \
  "https://api.open-meteo.com/v1/forecast?$QUERY&current=temperature_2m,wind_speed_10m&forecast_days=1" \
  | jq '{current_units, current}'
```

This direct call establishes what the useful upstream response looks like.
The temperature and timestamp change with the forecast. Coordinates may be
rounded to the weather model's grid cell.

## 3. Obtain the human's ID token

A **human** delegates authority to an agent. First, authenticate Alice with
the bundled development identity provider:

```bash
ID_TOKEN=$(curl --fail --silent --show-error "$DEX/dex/token" \
  --data-urlencode grant_type=password \
  --data-urlencode client_id=agent-gateway \
  --data-urlencode scope=openid \
  --data-urlencode username=alice@example.com \
  --data-urlencode password=password \
  | jq -er '.id_token')
```

This password grant is enabled in **local demo Dex** so the entire exercise
works via curl. In a real deployment, obtain the human's ID token through
your organization's supported OIDC sign-in flow. The authorization service
verifies the signed token; the client does not choose the delegating identity.

## 4. Create a narrowly scoped delegation

Allow reads on exactly two paths for 30 minutes. Add a rule requiring approval
for elevation reads, to demonstrate a hold on a harmless operation:

```bash
DELEGATION=$(curl --fail --silent --show-error "$AUTHZ/v1/delegations/" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg id_token "$ID_TOKEN" '{
    id_token: $id_token,
    agent_id: "weather-tutorial-agent",
    resources: ["/v1/forecast", "/v1/elevation"],
    actions: ["read"],
    expires_in_seconds: 1800,
    max_depth: 0,
    approval_rules: [{
      when: {resource_pattern: "/v1/elevation", action_pattern: "read"},
      require: true,
      rationale: "Elevation lookups need a human decision in this tutorial"
    }]
  }')")

DELEGATION_ID=$(jq -er '.delegation.id' <<<"$DELEGATION")
AGENT_SECRET=$(jq -er '.agent_secret' <<<"$DELEGATION")
SUBJECT=$(jq -er '.delegation.user_id' <<<"$DELEGATION")
```

- **Resources** name the permitted paths; avoid a broad `*` grant.
- **Actions** use the gateway's mapping: GET/HEAD → `read`, POST → `create`,
  PUT/PATCH → `update`, DELETE → `delete`.
- **Expiry** ends the delegation even if you forget to revoke it.
- **Max depth 0** prevents the agent creating child delegations.
- **Approval rules** turn a matching allowed action into a human hold.

`SUBJECT` is the verified delegating user's identifier returned by the service.
It may differ from the email address. The one-time `AGENT_SECRET` and the
delegation ID are the credentials handed to the agent.

## 5. Mint the agent's short-lived token

```bash
AGENT_TOKEN=$(curl --fail --silent --show-error "$TS/token" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg id "$DELEGATION_ID" --arg secret "$AGENT_SECRET" '{
    delegation_id: $id, agent_secret: $secret, ttl_seconds: 300
  }')" | jq -er '.access_token')
```

There are three different credentials in this exercise:

| Credential | Used by | Purpose |
|---|---|---|
| `ID_TOKEN` | Delegating human | Create and revoke their delegation |
| `AGENT_SECRET` → `AGENT_TOKEN` | Agent | Mint tokens and call delegated APIs |
| `ADMIN_TOKEN` | Trusted operator | Record approvals and read audit events |

The agent does not need the human ID token or operator token. This teaching
script holds all three because it demonstrates both sides of the exchange.

## 6. Prove the access controls

These probes deliberately omit curl's `--fail` so you can inspect the expected
error bodies. `-w` prints the HTTP status after each response.

```bash
# No credential: expect 401.
curl -sS -w '\nHTTP %{http_code}\n' "$FORECAST"

# Delegated GET: expect 200 and Open-Meteo's current weather data.
curl -sS -w '\nHTTP %{http_code}\n' "$FORECAST" \
  -H "Authorization: Bearer $AGENT_TOKEN"

# POST maps to create, which was not delegated: expect 403.
curl -sS -w '\nHTTP %{http_code}\n' -X POST "$FORECAST" \
  -H "Authorization: Bearer $AGENT_TOKEN"

# This path was not delegated: expect 403, regardless of upstream support.
curl -sS -w '\nHTTP %{http_code}\n' "$GW/v1/marine?$QUERY" \
  -H "Authorization: Bearer $AGENT_TOKEN"
```

The successful response contains `current.temperature_2m` and
`current.wind_speed_10m`. The denials come from the gateway; Open-Meteo does
not need to implement these delegation rules.

## 7. Hold a request and record the human's decision

```bash
# Expect HTTP 202 and an approval_id, not elevation data.
HELD=$(curl -sS "$ELEVATION" -H "Authorization: Bearer $AGENT_TOKEN")
jq . <<<"$HELD"
APPROVAL_ID=$(jq -er '.approval_id' <<<"$HELD")
```

The gateway holds this request without forwarding it. **202 does not mean the
API operation ran**. Elevation reads are not inherently risky; this rule is
deliberately added to teach the approval mechanism.

Now act as the trusted operator recording Alice's decision:

```bash
curl --fail --silent --show-error "$GW/v1/approvals/" \
  -H "X-Admin-Token: $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg id "$APPROVAL_ID" --arg subject "$SUBJECT" '{
    approval_id: $id, approver_id: $subject, approved: true
  }')"
```

The approval endpoint requires the operator token and checks that
`approver_id` matches the delegating subject. In this demo, the operator
supplies that identity; the curl approval call itself does not authenticate
Alice via OIDC. Keep this endpoint behind trusted operator/human-facing
infrastructure in a real integration.

Approval records the decision; **it does not execute the request**. Retry:

```bash
# Expect 200 and {"elevation":[...]} in meters.
curl -sS -w '\nHTTP %{http_code}\n' "$ELEVATION" \
  -H "Authorization: Bearer $AGENT_TOKEN"

# Approval was consumed. Another identical lookup needs fresh consent: 202.
curl -sS -w '\nHTTP %{http_code}\n' "$ELEVATION" \
  -H "Authorization: Bearer $AGENT_TOKEN"
```

Reuse the identical URL when retrying. This exercise demonstrates single-use
consent; it does not establish query-parameter restrictions or query-specific
approval binding. We do not control Open-Meteo's server logs, so the evidence
here is the gateway's responses/audit and the returned elevation data. For
upstream execution-counter proof, run the
[protected API demo](Demos.md#demo-4--the-protected-api-demoapi-scripted).

## 8. Revoke access immediately

```bash
curl --fail --silent --show-error -X DELETE \
  "$AUTHZ/v1/delegations/$DELEGATION_ID" \
  -H "Authorization: Bearer $ID_TOKEN"

# Same agent token, previously working forecast URL: expect 403.
curl -sS -w '\nHTTP %{http_code}\n' "$FORECAST" \
  -H "Authorization: Bearer $AGENT_TOKEN"
```

The gateway checks delegation status on each call. Revocation overrides the
still-valid token and any outstanding approval. Do this within five minutes of
minting the agent token to distinguish revocation (**403**) from token expiry
(**401**). If it expired during the manual walkthrough, repeat step 5 before
revoking, then verify a forecast succeeds and proceed with revocation.

## 9. Inspect the audit trail with curl

```bash
curl --fail --silent --show-error \
  "$GW/v1/audit/?delegation_id=$DELEGATION_ID&limit=100" \
  -H "X-Admin-Token: $ADMIN_TOKEN" \
  | jq '.events[] | {
      ts, user_id, agent_id, delegation_id, resource, action,
      outcome, status_code, approval_id, approver_id, reason
    }'
```

Look for `allow` on the forecast, `deny` for scope violations and revocation,
and `approval_required` on elevation. The approved elevation execution carries
its approval ID and approver. Filtering by the delegation ID keeps other demo
runs out of this view. The no-token rejection has no delegation to attribute
and is not expected in this filtered result.

## 10. Clean up

The script revokes its delegation automatically; the manual flow does so in
step 8. If you stop the manual flow early, run the DELETE from that step.
The second held elevation request cannot execute after revocation.

To stop just the added weather gateway:

```bash
docker compose -f demo/docker-compose.yml -f demo/docker-compose.weather.yml \
  stop gateway-weather
```

If this stack was started solely for the tutorial, remove its containers with:

```bash
docker compose -f demo/docker-compose.yml -f demo/docker-compose.weather.yml down
```

`down` stops shared demo services too. Named database volumes are retained,
including the audit trail. Clear credentials from your shell when finished:

```bash
unset ID_TOKEN AGENT_SECRET AGENT_TOKEN DELEGATION ADMIN_TOKEN
```

## Troubleshooting

| Symptom | What to check |
|---|---|
| Connection refused | Finish `up -d --wait`; inspect `docker compose -f demo/docker-compose.yml -f demo/docker-compose.weather.yml ps`. |
| Port 8087 occupied | Prefix the startup command with `WEATHER_HOST_PORT=18087`, and run `WEATHER_HOST_PORT=18087 bash demo/public-weather-tutorial.sh`. For manual calls set `GW=http://localhost:18087` before step 2's URL variables. |
| Other ports occupied | Stop the conflicting local stack, or reuse the existing compatible demo authz/token/Dex services. |
| Dex sign-in fails | Use the bundled `demo/dex/config.yaml`; it enables the local password grant and Alice's fixture account. |
| 401 on an agent call | Token expired or is missing. Re-mint before revocation, or rerun the script; complete its approval pause within five minutes. |
| 403 on a forecast before revocation | Verify the delegation contains `/v1/forecast` and `read`, and is not expired/revoked. |
| Approval returns 401 / 403 / 410 | Check the operator token / delegating subject / approval expiry respectively. This gateway uses a 15-minute approval TTL. |
| 429, 5xx, or weather data unavailable | Check Open-Meteo availability and usage limits, container DNS, HTTPS egress and CA trust. The script fails rather than treating an upstream error as success. |
| Image licence/decryption error | Check `demo/keys/` and [Security and Licensing](Security-and-Licensing.md). |

Service logs:

```bash
docker compose -f demo/docker-compose.yml -f demo/docker-compose.weather.yml \
  logs --tail=80 gateway-weather authz tokensvc dex
```

## Applying this to your own API

Change `UPSTREAM_URL` to your API's origin and choose explicit resources and
actions that match its routes. Use approval rules for operations that need
human consent. Keep these implementation boundaries in mind:

- Delegation resources here match **paths**, not latitude, longitude or other
  query parameters. This configuration is not a location filter or rate limit.
- The gateway supports caller-supplied `X-Agent-Resource`, `X-Agent-Action`
  and `X-Agent-Tool` overrides. To enforce path/method rules for untrusted
  callers, strip or reject those headers at a trusted ingress before the PEP;
  these tutorial curls do not send them.
- Treat the upstream as a trusted recipient: the reverse proxy can forward
  request headers, including `Authorization`. These commands use only local
  demo credentials. Configure credential stripping/replacement at the upstream
  hop before routing real credentials to a third party.
- The shared base Compose stack uses development credentials and publishes
  its authz/token/Dex ports. Use it locally. Deploy your own identity provider,
  secrets, TLS and restricted management access for real use.

Next: [Protecting your API](Protecting-Your-API.md) for all delegation fields,
[Agent authentication basics](Agent-Auth-Basics.md) for the credential flow,
and [Deployment Guide](Deployment-Guide.md) for deployment configuration.

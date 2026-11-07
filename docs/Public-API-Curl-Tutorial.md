# AWS weather demo: Cognito sign-in and curl probes

This is the AWS adaptation of the weather tutorial. The upstream is
`https://api.open-meteo.com`; the agent calls **your AWS public gateway**, not the
provider directly. The demo needs a deployed weather-enabled Agent Gateway stack
and an invited Cognito operator. **That first AWS deployment is still pending.**

## 1. Get the correct release and URLs

```sh
git switch aws
git pull --ff-only origin aws
```

Your deployment operator supplies:

- **ConsoleURL**: your stack's HTTPS web console.
- **GatewayURL**: its public `https://ID.execute-api.eu-west-3.amazonaws.com` gateway.
- Your Cognito invitation and the operator email included in the console allowlist.

The [operator deployment notes](Deployment-Guide.md) explain enabling the exact weather routes and
credential stripping. Your operator must supply a compatible weather-enabled deployment.
Do not substitute a pre-existing live site, localhost/Dex address, internal API URL,
shared demo token or older encrypted container image. This is a REST demonstration;
Open-Meteo is not an MCP server and this is not an MCP connector acceptance test.

## 2. Sign in as the delegating human

Open your own ConsoleURL, sign in through Cognito, change the invitation password
privately and return to the application. Use an email you control that is included
in the deployed allowlist. No password grant or fixture Alice/password is used.

The console retains the verified human token server-side. Your agent needs only
its own short-lived agent token, not that human token or an IAM/admin credential.

## 3. Create a scoped delegation

The exact non-secret payload is in [demo/weather-delegation.json](../demo/weather-delegation.json).
It grants read access only to forecast/elevation, expires after 30 minutes and
requires human approval for elevation. The basic console form does not expose
arbitrary path approval rules, so open your browser's developer console on **your
own signed-in ConsoleURL** and run:

```javascript
const response = await fetch('/api/delegations', {
  method: 'POST', credentials: 'same-origin',
  headers: {'Content-Type': 'application/json'},
  body: JSON.stringify({
    agent_id: 'aws-weather-test',
    resources: ['/v1/forecast', '/v1/elevation'],
    actions: ['read'], expires_in_seconds: 1800, ttl_seconds: 300, max_depth: 0,
    approval_rules: [{
      when: {resource_pattern: '/v1/elevation', action_pattern: 'read'},
      require: true, rationale: 'AWS weather demo: elevation needs a human decision'
    }]
  })
});
if (!response.ok) throw new Error('Delegation creation failed: ' + response.status);
window.agwWeather = await response.json();
console.log({delegation_id: window.agwWeather.delegation.id});
```

The response includes `token` and the one-time `agent_secret`. Copy
`window.agwWeather.token` privately for the next step. Do not post token values,
passwords, cookies, screenshots containing them or browser HAR files in Git/chat.
The client cannot choose the delegating human; the server attaches its verified
session identity to this request.

## 4. Run the access checks

In Bash, set the **public** GatewayURL. The script validates the root AWS API host,
uses TLS verification and does not follow redirects. It cannot safely send agent
credentials directly to Open-Meteo or an arbitrary custom URL.

```sh
export GATEWAY_URL='https://REPLACE.execute-api.eu-west-3.amazonaws.com'
read -r -s -p 'Agent token: ' AGENT_TOKEN; printf '\n'
export AGENT_TOKEN
bash demo/public-weather-tutorial.sh access
```

Replace the URL, including the lowercase API ID. The checks are:

| Probe | Expected |
| --- | --- |
| Forecast without a token | 401 |
| Forecast with the delegated token | 200, including actual temperature/wind fields |
| POST with the read-only delegation | 403 |
| `/v1/marine`, outside the delegation | 403 |
| POST with a forged `X-Agent-Action: read` | 403; the actual method controls policy |
| Elevation without human consent | 202 and an approval ID |

The script prints the approval ID, never your token. It sends London's coordinates
and requests temperature/wind plus elevation. Weather data changes over time. It
asserts response fields/statuses and exits nonzero on failure; provider errors are
not treated as success. A 202 means the weather lookup has **not** been executed.

## 5. Approve and retry

In the signed-in console, find that approval ID and approve it as the same human
who created the delegation. This records consent; it does not execute the request.
Then run:

```sh
bash demo/public-weather-tutorial.sh approved
```

Expected: elevation returns 200 with a real nonempty `elevation` array once. The
next identical lookup returns 202 because approval was consumed. The script never
approves on behalf of the user and has no unattended `--yes` mode.

Tokens last five minutes. If you need a fresh token **before revocation**, run this
in the same signed-in browser console, then privately replace `AGENT_TOKEN` in Bash:

```javascript
const minted = await fetch('/api/tokens', {
  method: 'POST', credentials: 'same-origin',
  headers: {'Content-Type': 'application/json'},
  body: JSON.stringify({delegation_id: window.agwWeather.delegation.id,
    agent_secret: window.agwWeather.agent_secret, ttl_seconds: 300})
});
if (!minted.ok) throw new Error('Token mint failed: ' + minted.status);
window.agwWeather.token = (await minted.json()).access_token;
```

## 6. Revoke while the token is still valid

Revoke the delegation in your signed-in console. Do not mint a new token after
revocation. Retry the previous token promptly:

```sh
bash demo/public-weather-tutorial.sh revoked
```

Expected: 403. A token-expiry 401 is a failed revocation proof, not a passing result.
If it expires too early, create a fresh test delegation and repeat the sequence.
Inspect the console audit for this delegation's allow/hold/deny outcomes, the
approved elevation's approval ID and the verified approver identity.

## 7. Finish

```sh
unset AGENT_TOKEN GATEWAY_URL
```

Delete `window.agwWeather` in the browser (`delete window.agwWeather`) and sign out.
A second held request cannot execute under the revoked delegation. The shell client
does not automatically revoke or tear down anything; these are deliberate human/
operator actions. If the AWS stack was created only for this test, use [teardown](Teardown.md).

## Boundaries and troubleshooting

- Gateway path scope is not a latitude/longitude filter or query-specific approval binding.
- This public provider can still be called directly; enforce agent network egress
  separately if all outbound traffic must use your gateway.
- Provider-side execution counters are not observable. Audit/status/returned JSON
  are the evidence here; no claim is made that upstream executions were independently counted.
- Missing weather routes (404): verify `EnableWeatherDemo=true` and the compatible source release.
- Unexpected 401: token missing/expired, or wrong service URL.
- Unexpected 403: check the exact delegation paths/actions, revocation and IAM logs.
- 429/5xx: stop retries and check provider limits, upstream availability and CloudWatch.
- Console login/creation failures: operator checks Cognito callbacks, invitation,
  signed internal hops and server logs; do not make management APIs public to fix them.

[Weather data by Open-Meteo.com](https://open-meteo.com/). Review current
[terms](https://open-meteo.com/en/terms) and [pricing](https://open-meteo.com/en/pricing).
The free provider endpoint is for evaluation/non-commercial use within its limits;
commercial/promotional use needs an appropriate provider arrangement. Keep this
acceptance run small. The script's offline checks are `make check`; no real AWS
acceptance run has been completed yet.

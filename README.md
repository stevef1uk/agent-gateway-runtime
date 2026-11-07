# Agent Gateway AWS demo

Give an AI agent read access to weather data, require human approval for one lookup,
and revoke access while its token is still valid. This **`aws` branch** starts with
just the Open-Meteo weather demo.

## Choose how to use it

**Use a hosted demo:** your operator supplies a console URL, public gateway URL and
Cognito invitation. You need no AWS account, private source code, Docker, SDK or API
key. Follow the [weather walkthrough](docs/Public-API-Curl-Tutorial.md).

**Deploy in your own AWS account:** see the separate [Self-hosting guide](docs/Self-Hosting.md).
That path requires a compatible deployment release; it is not yet published.

**AWS Marketplace:** planned as a purchase/distribution channel. See the separate
[Marketplace guide](docs/AWS-Marketplace.md) for hosted and customer-account delivery
scope. There is no published listing or subscription/entitlement integration yet.

**Availability:** the implementation is locally tested, but the first real AWS
application deployment/acceptance run is still pending. There is no hosted AWS demo
URL or third-party deployment bundle published by this branch yet. Ask your operator
for access when the test deployment is ready. Existing live sites and the `main`
branch's local demos are not this AWS release.

## Hosted-demo quick start

Install Git, Bash, curl and Python 3. Then:

```sh
git clone --branch aws https://github.com/stevef1uk/agent-gateway-runtime.git
cd agent-gateway-runtime
```

1. Open the console URL from your operator and sign in through Cognito.
2. Create the scoped test delegation using the [walkthrough](docs/Public-API-Curl-Tutorial.md#3-create-a-scoped-delegation).
3. In Bash, use your own public GatewayURL and privately copy the agent token:

```sh
export GATEWAY_URL='https://REPLACE.execute-api.eu-west-3.amazonaws.com'
read -r -s -p 'Agent token: ' AGENT_TOKEN; printf '\n'
export AGENT_TOKEN
bash demo/public-weather-tutorial.sh access
```

4. Approve the held elevation lookup in the console, then:

```sh
bash demo/public-weather-tutorial.sh approved
```

5. Revoke the delegation in the console while the token is still valid, then:

```sh
bash demo/public-weather-tutorial.sh revoked
unset AGENT_TOKEN GATEWAY_URL
```

The client reports PASS/FAIL, checks real weather fields, and never makes human
approval decisions. Tokens expire after five minutes; the walkthrough explains how
to refresh one before testing revocation. Do not share tokens or browser cookies.

## What to expect

| Test | Result |
| --- | --- |
| No agent token | 401 |
| Delegated forecast GET | 200 with real weather JSON |
| Wrong method/path or forged mapping header | 403 |
| Elevation before consent | 202, held |
| Approved elevation retry | 200 once; a further request needs fresh consent |
| Same valid token after delegation revocation | 403 |

The signed-in human views the audit trail in the console. Open-Meteo stays public;
this proves control through your gateway, not prevention of all direct Internet
access. This REST demo does not claim MCP, DPoP-signing, proxy or production HA
acceptance. See [architecture](docs/Architecture.md) for limits.

## Help and checks

- [Full weather walkthrough and troubleshooting](docs/Public-API-Curl-Tutorial.md).
- [Self-hosting](docs/Self-Hosting.md), [costs](docs/Pricing.md) and [cleanup](docs/Teardown.md).
- [Operator deployment notes](docs/Deployment-Guide.md) — not required for using a hosted demo.
- `make check` runs syntax/fake-curl tests without network or AWS calls.

[Weather data by Open-Meteo.com](https://open-meteo.com/). Review its
[terms](https://open-meteo.com/en/terms) for evaluation/non-commercial use and limits.
No paid weather subscription is created by the client.

See [LICENSE](LICENSE) and [SECURITY.md](SECURITY.md). This demo repository's licence
does not grant rights to private implementation binaries or source.

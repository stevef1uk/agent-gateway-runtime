# Commercial licence — terms you accept when you run the software

The software is distributed as pre-built Docker images under a commercial
licence from Steve Fisher. This page states, in plain language, what the
licence grants, what it **does not promise**, and how liability is limited —
the protections a normal commercial software vendor operates under. The full
legal text ships with the images (see §Complete terms below).

## The one-paragraph summary

You get a licence to *run* the software (and, with the Software Licence tier,
the *source*), subject to an annual licence token. You get best-effort email
support but **no SLA**. The software is provided **"AS IS", with all faults,
without any warranty of fitness for your particular purpose** — you must
evaluate it before using it in production. The vendor's aggregate liability
is capped at the fees you paid in the last 12 months (nil on free tiers).
Every consequential action an agent performs under a human delegation remains
**your organisation's** responsibility: the gateway *records* decisions, it
does not *make* them.

## What you receive (per licence)

- The right to run the published images (`stevef1uk/agent-gateway-*`) for
  internal business purposes, with your own customer key pair and licence
  token
- Updates and security fixes on a best-effort basis for the licence period
- Email support (steve@sjfisher.com) — no response-time or uptime commitment

## What the licence does NOT promise

| Promise you should NOT assume | Reality |
|---|---|
| "It is fit for my purpose" | **No warranty of fitness.** You (the licensee) evaluate suitability in a non-production environment at your own cost before production use. Production use = acceptance as-is, faults included |
| "It will be uninterrupted / bug-free / secure" | No such warranty — with unlimited replicas you manage availability yourself; security controls beyond the shipped software are your runbook |
| "The vendor is liable if something goes wrong" | **Liability is capped** at fees paid in the preceding 12 months (nil on free tiers), and excludes indirect/consequential losses (lost profits, data, business interruption), in all cases to the maximum extent the law permits |
| "The vendor vouched for my compliance posture" | No. Compliance (financial-industry, data protection, AI-use regulation) is **solely the licensee's responsibility** |
| "Human approvals make the agent's action the vendor's problem" | The gateway records decisions; it does not make them. The human who approves/delegates and the organisation behind the agent remain fully responsible for every consequential outcome |
| "I can use it wherever failure is catastrophic" | **No high-risk use** (nuclear, aviation/ATC, medical/life-support, weapons) without written agreement, and then entirely at the licensee's own risk |

## Licensee indemnity (what you cover)

You indemnify the vendor against claims arising from your deployment,
configuration or operation of the software, the data you route through it,
the actions of agents acting under your delegations, your breach of the
licence, and any regulatory, compliance or trading outcome of decisions made
with or recorded by the software.

## Renewal & expiry

Licences are vendor-signed tokens with an expiry date enforced at
start-up (see [Security-and-Licensing.md](Security-and-Licensing.md)).
Renewal is a new token file plus a service restart. Non-production
environments remain free of charge at every tier.

## No-SLA support

Support is email at every paid tier — your tickets are prioritised by tier,
but no response-time, uptime or availability commitment exists at this stage
(see [Pricing.md](Pricing.md) §Support levels).

## Complete terms

The full agreement (definitions, grant, restrictions, expiry, warranty
disclaimer, fitness/acceptance clause, high-risk-activity clause, limitation
of liability, licensee indemnity, IP, termination, governing law — England)
ships with each customer licence and is available on request:
**steve@sjfisher.com**.

Nothing in these terms excludes liability that cannot lawfully be excluded
(such as death or personal injury caused by negligence, or fraud).

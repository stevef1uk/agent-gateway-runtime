# Pricing

> French TVA (currently 20%) applies to all prices where applicable.

## How licensing works

Agent Gateway ships as encrypted Docker images. A purchase produces two
artifacts that activate it:

1. your **customer key pair** — the public half is baked into your build of
   the images, the private half decrypts the binaries at runtime (never share,
   mount at `/keys`);
2. a vendor-signed **licence token** with an expiry date — mounted at
   `/licences/<service>.token`, checked at every service start.

So a paid licence is literally: two files from the vendor (your private key
and a licence token), a mount line, and one `docker compose up -d`. Licences
expire annually **for paid tiers that bill annually**; renewal is a new token
file from us plus a service restart — an ops step, not an audit. User,
Developer and other free tiers are issued **non-expiring** vendor-licensed
tokens by email — the product is free, but it still runs under our key
material and this licence, which is what keeps the vendor relationship and
update channel intact.

## Tiers

### Users & Developers — free

The product is **free** for individual users, developers and indies: one
production deployment (a complete four-service stack, any replicas you like),
unlimited non-production use, and community support. **Email
steve@sjfisher.com for a non-expiring licence token** — issuance is manual
so we know who is running what and can warn you about breaking updates.
The demo stack in this repository can be used as-is today.

### Business — book a week with me

Moving to production beyond a pilot, wiring your own IdP, integrating agents
against internal back ends, SPIFFE/SPIRE enablement, or standing up the
Postgres/Redis/Kubernetes HA deployment: book the vendor for a **one-week
engagement** (rates and dates agreed at scoping, travel excluded, invoiced
up-front). You get implementation and enablement on your environment, and a
production deployment the team actually understands. Ongoing email support
remains best-effort, no SLA.

### Software Licence (source) — €5,000 one-off

Permanent, royalty-free licence to the full source code: internal
modifications permitted, no annual renewals, no seat or deployment limits,
no maintenance commitment of any kind. Updates and fixes after purchase are
supplied only if the vendor chooses to, and may be quoted separately.

## Support levels (current stage)

Support is **by email** (steve@sjfisher.com) at every tier. There is
**no formal SLA** at this stage:

- **Business / Source** — your request goes to the front of the queue;
  a named contact; releases and fixes prioritised for you.
- **Users & Developers (free)** — community only: the public demo repository
  and the troubleshooting tables in these docs.

Included at Business and above: upgrade guidance, licence renewal swaps,
integration questions (OIDC, SPIFFE, Postgres/Redis) and bug fixes in
shipped images.

## The licence itself

Every tier — including free — runs under the same commercial licence:
AS-IS, no warranty of fitness, liability capped at fees paid (nil when none
were paid), and human decisions about agent actions stay the licensee's
responsibility. See [Commercial-Licence.md](Commercial-Licence.md).

## Questions

Licensing questions and token issuance: **steve@sjfisher.com**
(French VAT number on invoices as applicable).

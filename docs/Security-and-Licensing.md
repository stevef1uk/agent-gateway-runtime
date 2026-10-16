# Security & Licensing model

How the Agent Gateway binaries are packaged, protected and licensed — and
what you are responsible for.

## The packaging model

Every service image (`stevef1uk/agent-gateway-{authz,gateway,tokensvc,web}`)
is built with a three-stage Docker build:

1. **Build stage** — the Go code is compiled into a static binary.
2. **Packaging stage** — the binary is placed in a payload directory and
   sealed with the [secure-packager](https://hub.docker.com/r/stevef1uk/secure-packager)
   tool:
   - **envelope encryption** — the payload is encrypted to the *customer
     public key* (baked into the image at build time); only the matching
     private key can decrypt it;
   - **vendor licence manifest** — the package carries `license_required` and
     the *vendor public key*; the decrypted runtime refuses to start without
     a valid, vendor-signed licence token;
   - the result is a single encrypted `.zip` inside the runtime image, plus
     the small `unpack` helper.
3. **Runtime stage** — a tiny Alpine image with **only** the encrypted
   payload, the unpack tool and an entrypoint: no plaintext binary ever
   exists in the image or in the registry.

## What happens at start-up

```
1. read the licence token from /licences/<service>.token
2. check expiry/signature against the baked-in vendor public key
   → expired or missing token: clear error, container exits
3. unpack the encrypted payload with the customer private key at
   /keys/customer_private.pem
   → wrong key: unpack fails with a decryption error
4. exec the decrypted binary
```

Four consequences:

- **Images alone are inert.** Copying them from Docker Hub gives nothing
  without your private key *and* a valid licence token.
- **Expiry is enforced by execution**, not by bookkeeping: an expired licence
  is a loud start-up failure (see [Demos.md](Demos.md) troubleshooting), so a
  subscription lapse cannot silently degrade security.
- **The vendor signature is the enforcement anchor** (right-to-run, expiry,
  who it was issued to); the customer key pair is the confidentiality anchor
  (only the paying customer can run the software).
- **Keys cannot be rotated in-place** without a new image build — public keys
  are baked in at build time. Contact the vendor for a key-rotation build.

## Artifact responsibilities (yours vs ours)

| Artifact | Held by | Notes |
|---|---|---|
| `customer_private.pem` | **you** | never in images, never in git; mount read-only `/keys/customer_private.pem`. Loss = vendor rebuild with a new key pair. |
| `customer_public.pem` | baked into images | identifies your decryptability, not a secret |
| `vendor_public.pem` | baked into images | verifies licence tokens |
| `vendor_private.pem` | **vendor only** | signs licence tokens. **Never** distributed |
| `license.token` | you (file) | vendor-signed, expiry carried inside; replace at renewal and restart |

## Licence tokens

A token is a base64 field pair: `expiry:company:email` plus an HMAC signature
from the vendor key over the whole record. The runtime parses the expiry and
rejects tokens dated in the past, passing the token to `unpack` which
verifies the signature against the vendor public key. Token issuance is a
vendor-side operation (`issue-token`), delivery is an email attachment; the
renewal runbook is a file swap + `docker compose restart` — the publisher
runbook in [Deployment-Guide.md](Deployment-Guide.md).

## Evaluation & demo keys

The [public demo repository](../README.md) ships `demo/keys/` containing a
development key pair and a token — that is what makes the public images run
without contacting the vendor. Understand what this means:

- the demo private key is **public** — it proves the packaging mechanics work,
  and it does not compromise any *other* customer, because each paying
  customer's images are built with *their own* public key;
- the demo licence token carries an expiry date — extendability and renewals
  are exactly what a paid licence changes;
- anything you run with demo keys is still a **development environment**: use
  the normal [Deployment-Guide.md](Deployment-Guide.md) hardening for real
  workloads; request your own customer key pair and token by email.

## Licence liability, in one section

The commercial licence is a standard AS-IS grant: no warranty of
merchantability or fitness for your purpose, you must evaluate in
non-production before production use, licensee indemnity on agent actions,
and the vendor's aggregate liability capped at fees paid in the prior
12 months (nil on free tiers). Full text:
[Commercial-Licence.md](Commercial-Licence.md).

## Hardening checklist for the container runtime

From [Deployment-Guide.md](Deployment-Guide.md), the minimum:

- mount `keys/` and `licences/` read-only (`:ro`)
- keep `JWT_SECRET` (32+ random bytes) identical across authz/tokensvc/gateway
- run behind your own TLS termination; choose SPIFFE mTLS mode for agents
  where feasible
- ship logs to your SIEM — every allow/deny lives in `audit_events`
- restart cadence: tokens reload at container start; a token replacement does
  not require an image pull — only a restart

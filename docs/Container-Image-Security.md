# Verifying Agent Gateway container images

This guide is for users who want to verify that an Agent Gateway image digest
was approved by its publisher before running it.

## What verification establishes

A Cosign signature binds a publisher identity to an image digest. If a
version tag is moved to different content, that content has a different
digest and will not verify under the old signature. Always verify and deploy
an immutable `repository@sha256:...` reference rather than relying on a
mutable tag such as `latest`.

A valid signature means the trusted signer approved that exact digest. It
does not prove the image is vulnerability-free or that a particular source
commit produced it. A signed licence token is not an image signature and does
not authenticate the image publisher or contents.

Cosign signatures are separate artifacts in the registry. Signing an
already-published image does not rebuild or modify it, change its digest, or
change its runtime keys. Cosign signing credentials are separate from the
customer/vendor keys used by the secure-packager licensing system.

## 1. Find the exact image digest

Use the immutable image reference from the release information for the
platform you deploy. For example:

* AWS: the `immutable_image` values in the [AWS release manifest](https://github.com/stevef1uk/agent-gateway-runtime/blob/aws/releases/current.json).
* Azure: the digest-pinned image references in the [Azure example configuration](https://github.com/stevef1uk/agent-gateway-runtime/blob/azure/deploy/azure/azure-config.example.json).
* GCP: the deployed Artifact Registry digest recorded by the operator. GCP
  deployments may mirror Docker Hub images, so verify the digest in the
  registry from which you actually pull.
* Docker Compose: the default references in
  [`demo/docker-compose.yml`](../demo/docker-compose.yml) pin the version and
  OCI digest. For image overrides, verify the digest against the release
  record; do not rely on a tag-only reference.

The signed digests listed below cover the specified Docker Hub main-release
and Compose support images. The platform-specific AWS (`_l`), Azure
(`_azure`), and GCP (`_g`) releases use separate signer identities and
digests; do not use the main-release identity to verify them.

For a public Docker Hub tag, inspect the registry manifest with Docker Buildx:

```bash
docker buildx imagetools inspect docker.io/stevef1uk/agent-gateway-gateway:1.0.36
```

Use the digest only when it matches the publisher's trusted release record.
The tag-to-digest result from a registry by itself does not prove who
published the image.

## 2. Verify the publisher signature

Install Cosign from its official distribution channel. For keyless signing,
use the exact certificate identity and OIDC issuer that signed the release.
For the `agent-gateway` main-branch image-signing workflow, the identity is:

```bash
SIGNER_ID='https://github.com/stevef1uk/agent-gateway/.github/workflows/sign-main-images.yml@refs/heads/main'
OIDC_ISSUER='https://token.actions.githubusercontent.com'

cosign verify \
  --certificate-identity "$SIGNER_ID" \
  --certificate-oidc-issuer "$OIDC_ISSUER" \
  'docker.io/stevef1uk/agent-gateway-gateway@sha256:2dce006ce0b53bdeb57525b3d993809fbc802a24e1dcfd39e46dde1a4ee72ce8'
```

If the publisher instead distributes a public key and its fingerprint through
a trusted channel, verify with that key:

```bash
cosign verify --key /path/to/publisher-cosign.pub "$IMAGE"
```

Do not guess the signer identity or trust an identity copied from the
registry. A verification failure means stop: check the digest and trusted
signing information before running the image.

### Currently verified main-release images

The images below were built and published on 2026-11-18, then signed by the
GitHub Actions workflow identity above. Each signature was independently
verified with Cosign. These are multi-platform image-index digests, and the
Docker Hub `:latest` aliases currently resolve to the same digests. Prefer
the immutable references below in deployments.

| Image | Version tag | Verified image digest |
|---|---|---|
| Authz | `1.0.16` | `docker.io/stevef1uk/agent-gateway-authz@sha256:a0ce26b4f5fabae96e084d15b9777c4a730c6e530c1c4e5393e7ea170b22357f` |
| Token service | `1.0.10` | `docker.io/stevef1uk/agent-gateway-tokensvc@sha256:e62ede0ee3a8308ccc5a060d95b9b2159f34b653b56514f3102833a8b5faff1c` |
| Gateway | `1.0.36` | `docker.io/stevef1uk/agent-gateway-gateway@sha256:2dce006ce0b53bdeb57525b3d993809fbc802a24e1dcfd39e46dde1a4ee72ce8` |
| Web | `1.0.61` | `docker.io/stevef1uk/agent-gateway-web@sha256:12c13a7240547ed43b7cd84c37d24b751d29a0b1eef5f3fb0095acd3b9f0cc4d` |

To re-verify all four from the runtime repository root, run:

```bash
./verify-images.sh
```

The script checks every image and reports failures without stopping at the
first one. Run it from an existing terminal so the output remains visible.

The signatures authenticate approval of these digests by the specified
workflow identity. They do not prove a source commit or observed build process.

### Compose support images

The [Sign Compose support images run](https://github.com/stevef1uk/agent-gateway/actions/runs/43830359477)
signed these existing image indexes on 2026-11-16. Each signature was
independently verified with the exact identity shown below.

| Image | Compose tag when signed | Verified image digest |
|---|---|---|
| FreeRide | `1.4.0` | `docker.io/stevef1uk/freeride@sha256:59171d738c83a6f50ef07fd1ab3632f685b889fc6a3a7f0716c48333ed1b7174` |
| Demo MCP server | `1.0.1` | `docker.io/stevef1uk/agent-gateway-mcpsrv@sha256:31f23588e0dbecd9588677ba9def5744c30a73b47fb03cbfaa41feb2525c099a` |
| Emotion MCP | `latest` | `docker.io/stevef1uk/emotion-mcp@sha256:e3f9eee22aaec137290c1fc3f16845d56401b91ed46147e3f7dca4b503760a01` |

`latest` is mutable: a later Emotion MCP image is not covered by this
signature unless it has the same digest. Verify each digest before deployment:

```bash
set -euo pipefail
SIGNER_ID='https://github.com/stevef1uk/agent-gateway/.github/workflows/sign-demo-images.yml@refs/heads/main'
OIDC_ISSUER='https://token.actions.githubusercontent.com'
images=(
  docker.io/stevef1uk/freeride@sha256:59171d738c83a6f50ef07fd1ab3632f685b889fc6a3a7f0716c48333ed1b7174
  docker.io/stevef1uk/agent-gateway-mcpsrv@sha256:31f23588e0dbecd9588677ba9def5744c30a73b47fb03cbfaa41feb2525c099a
  docker.io/stevef1uk/emotion-mcp@sha256:e3f9eee22aaec137290c1fc3f16845d56401b91ed46147e3f7dca4b503760a01
)
for image in "${images[@]}"; do
  cosign verify \
    --certificate-identity "$SIGNER_ID" \
    --certificate-oidc-issuer "$OIDC_ISSUER" \
    "$image"
done
```

The four main images also contain BuildKit-generated SPDX SBOM and SLSA
provenance attestation manifests. They were emitted during the multi-platform
build with `--sbom=true` and `--provenance=true`. The Cosign signatures
above authenticate the complete OCI index digest, including its references to
the attestation manifests. These BuildKit attestations are not separate
Cosign-signed statements: `cosign verify-attestation` does not verify them
and will report no matching attestations. Inspect the index descriptors with:

```bash
docker buildx imagetools inspect \
  docker.io/stevef1uk/agent-gateway-gateway@sha256:2dce006ce0b53bdeb57525b3d993809fbc802a24e1dcfd39e46dde1a4ee72ce8
```

Look for `unknown/unknown` attestation manifests and the
`vnd.docker.reference.type: attestation-manifest` annotation. Do not treat
these attestations as independent build verification or proof of a SLSA
level; provenance describes the local BuildKit build and is only as trustworthy
as the publisher and build environment.

## Runtime keys are separate

The secure-packager keys that make the application image run are not Cosign
keys:

* The image contains payload encrypted for the matching customer public key
  and licence verification using the vendor public key.
* Operators provide the matching customer private key and vendor-issued
  licence token at runtime.
* Cosign verifies who approved the image digest; it does not decrypt the
  image, issue a licence, or replace these runtime materials.

Signing an existing image does not rotate or change any of these keys. Do not
regenerate the application keys to enable Cosign verification.

## Local Compose demo images

The demo Compose defaults select the current signed, digest-pinned main
images; Compose does not build these images automatically. For the exact
local image IDs used in the STRIX run, follow the
[step-by-step local Google IdP procedure](Deployment-Guide.md#local-google-idp-test).
That procedure sets all four image overrides. Do not treat the currently
published signed digests as STRIX-tested: STRIX tested the local images only.

Build from the product source checkout using the customer and vendor public
keys that match the private key and licence mounted by the demo:

```bash
AGW_SOURCE=/path/to/agent-gateway
docker build --pull \
  -f "$AGW_SOURCE/docker/Dockerfile.gateway" \
  --build-arg CUSTOMER_PUBLIC_KEY=keys/customer_public.pem \
  --build-arg VENDOR_PUBLIC_KEY=keys/vendor_public.pem \
  -t agent-gateway/gateway:security-test "$AGW_SOURCE"
docker build --pull \
  -f "$AGW_SOURCE/docker/Dockerfile.web" \
  --build-arg CUSTOMER_PUBLIC_KEY=keys/customer_public.pem \
  --build-arg VENDOR_PUBLIC_KEY=keys/vendor_public.pem \
  -t agent-gateway/web:security-test "$AGW_SOURCE"
```

Do not use the generated public keys with a different mounted private key or
licence. Only public keys belong in the build context/build arguments. Keep
private keys, licence tokens, JWT secrets, and IdP credentials local and
uncommitted; never pass them as build arguments.

Run `demo/ensure-secrets.sh` to create the ignored `demo/.env` with independent
high-entropy service secrets. Never commit this file.

The default `docker-compose.yml` is a **local demo mode**, not a secure
deployment: it binds published ports to loopback and uses a shared Dex account
(`alice@example.com` / `password`) so the walkthrough works immediately. Do
not expose it to a network or deploy it. The shared-account default is not
suitable for security testing; use the hardened overlay and a real IdP.

### Harden the stack with Google or Microsoft sign-in

For security testing or a self-hosted deployment, use the hardened overlay.
It replaces the fixture Dex config with a generated Google/Microsoft config
and requires an explicit administrator email allowlist. The Compose ports
remain bound to loopback; put a TLS reverse proxy in front if users need
remote access. The proxy should forward the console and Dex callback paths to
this host.

1. For local Google testing, start a temporary HTTPS tunnel to Dex using the
   Docker command in the [local Google IdP
   guide](Deployment-Guide.md#local-google-idp-test). The guide explains
   exactly where to copy the tunnel URL from its output and the trust,
   public-exposure, mutable-tag, and Docker-network risks of the third-party
   `cloudflare/cloudflared` image. Create an OAuth
   application in Google Cloud or Microsoft Entra ID and register the HTTPS
   URL `<DEX_ISSUER_URL>/callback` as its redirect URI. For remote use,
   configure the issuer and callback behind your TLS reverse proxy. A
   customer-controlled DNS name can provide a stable hostname, but DNS alone
   does not provide public network reachability or TLS; see the deployment
   guide before exposing services.
2. Set `DEX_UPSTREAM_CLIENT_ID`, `DEX_UPSTREAM_CLIENT_SECRET`,
   `DEX_ISSUER_URL`, `DEX_UPSTREAM_REDIRECT_URI`, `OIDC_CONNECTOR_ID`, and
   `WEB_ADMIN_EMAILS` in the ignored `demo/.env`. Use `google` or `microsoft`
   for `OIDC_CONNECTOR_ID`. `WEB_ADMIN_EMAILS` is a comma-separated allowlist
   of exact, verified account email addresses permitted to administer the UI.
   The issuer is the public HTTPS Dex URL, and the upstream redirect must be
   exactly that issuer plus `/callback`; the setup script validates the match.
   Set `WEB_PUBLIC_URL` to the console's public base URL; if exposing MCP OAuth
   through the proxy, also set `OAUTH_PUBLIC_BASE` (and, if used,
   `OAUTH_PUBLIC_BASE_EMOTION`).
3. Generate the hardened Dex configuration:

   ```bash
   cd demo
   python3 configure-idp.py
   ```

   This writes `demo/dex/config.hardened.yaml`, an ignored file with
   permissions restricted to the current user. The generated connector is
   Google (`type`/`id: google`) or Microsoft (`type`/`id: microsoft`,
   `tenant: common`). The script also registers exact console/MCP callback
   URLs derived from those public base URLs. The tracked
   `demo/dex/config.yaml` remains a credential-free template; Dex does not
   expand environment variables in its YAML file. The password connector in
   the generated config has no accounts.
4. Start or switch the stack with the hardened overlay:

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.egress.yml \
     -f docker-compose.opa.yml -f docker-compose.hardened.yml up -d
   ```

Only email-verified identities on `WEB_ADMIN_EMAILS` can administer the
console; other provider accounts are denied. Keep OAuth client secrets only
in the ignored `demo/.env` and generated ignored config, never in Compose or
tracked configuration. Re-run `python3 configure-idp.py` after changing those
credentials or the selected provider. The
Google and Microsoft connectors are documented in the [Dex connector
documentation](https://dexidp.io/docs/connectors/); see also [Google OAuth
setup](https://developers.google.com/identity/protocols/oauth2/web-server)
and [Microsoft identity platform setup](https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow).

Use the hardened overlay for the pen-test retest. The default local demo
account is intentionally insecure and will invalidate authentication-related
security results.

Run the retest against the locally served endpoint (normally
`http://localhost:8080`). Do not push or sign these local tags. Only publish
after the retest evidence is reviewed and the release digests are recorded.

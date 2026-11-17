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
* Docker Compose: the image tags in the
  [`demo/docker-compose.yml`](../demo/docker-compose.yml) file identify the
  intended versions, but tags alone are mutable. Resolve each tag to a digest
  and compare it with a publisher release record before relying on it.

The signed digests listed below cover the specified Docker Hub main-release
and Compose support images. The platform-specific AWS (`_l`), Azure
(`_azure`), and GCP (`_g`) releases use separate signer identities and
digests; do not use the main-release identity to verify them.

For a public Docker Hub tag, inspect the registry manifest with Docker Buildx:

```bash
docker buildx imagetools inspect docker.io/stevef1uk/agent-gateway-gateway:1.0.35
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
  'docker.io/stevef1uk/agent-gateway-gateway@sha256:a134b49079afd15f172c4f1926b94cb0eba8e38261e9409699c05e5e37375f47'
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

The images below were built and published on 2026-11-17, then signed by the
GitHub Actions workflow identity above. Each signature was independently
verified with Cosign. These are multi-platform image-index digests, and the
Docker Hub `:latest` aliases currently resolve to the same digests. Prefer
the immutable references below in deployments.

| Image | Version tag | Verified image digest |
|---|---|---|
| Authz | `1.0.15` | `docker.io/stevef1uk/agent-gateway-authz@sha256:b72fde17f16448f1fcafcc2e8a7303eddd98a9074d2ed6190b100e0778a2582c` |
| Token service | `1.0.9` | `docker.io/stevef1uk/agent-gateway-tokensvc@sha256:70f93246149afd85a71c4c63d7e043ecae7217634c2f961faa0834a5c513a748` |
| Gateway | `1.0.35` | `docker.io/stevef1uk/agent-gateway-gateway@sha256:a134b49079afd15f172c4f1926b94cb0eba8e38261e9409699c05e5e37375f47` |
| Web | `1.0.60` | `docker.io/stevef1uk/agent-gateway-web@sha256:c9def2de9387fd9156fedcce81bca7b64decaafeb378a5d057b56f090ab04c58` |

To re-verify all four, run:

```bash
set -euo pipefail
SIGNER_ID='https://github.com/stevef1uk/agent-gateway/.github/workflows/sign-main-images.yml@refs/heads/main'
OIDC_ISSUER='https://token.actions.githubusercontent.com'
images=(
  docker.io/stevef1uk/agent-gateway-authz@sha256:b72fde17f16448f1fcafcc2e8a7303eddd98a9074d2ed6190b100e0778a2582c
  docker.io/stevef1uk/agent-gateway-tokensvc@sha256:70f93246149afd85a71c4c63d7e043ecae7217634c2f961faa0834a5c513a748
  docker.io/stevef1uk/agent-gateway-gateway@sha256:a134b49079afd15f172c4f1926b94cb0eba8e38261e9409699c05e5e37375f47
  docker.io/stevef1uk/agent-gateway-web@sha256:c9def2de9387fd9156fedcce81bca7b64decaafeb378a5d057b56f090ab04c58
)

for image in "${images[@]}"; do
  cosign verify \
    --certificate-identity "$SIGNER_ID" \
    --certificate-oidc-issuer "$OIDC_ISSUER" \
    "$image"
done
```

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
build with `--sbom=true` and `--provenance=mode=max`. The Cosign signatures
above authenticate the complete OCI index digest, including its references to
the attestation manifests. These BuildKit attestations are not separate
Cosign-signed statements: `cosign verify-attestation` does not verify them
and will report no matching attestations. Inspect the index descriptors with:

```bash
docker buildx imagetools inspect \
  docker.io/stevef1uk/agent-gateway-gateway@sha256:a134b49079afd15f172c4f1926b94cb0eba8e38261e9409699c05e5e37375f47
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

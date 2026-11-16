# Verifying Agent Gateway container images

This guide is for users who want to verify that an Agent Gateway image digest
was approved by its publisher before running it. It applies to the AWS, Azure,
GCP and Docker Compose images.

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

For a public Docker Hub tag, inspect the registry manifest with Docker Buildx:

```bash
docker buildx imagetools inspect docker.io/stevef1uk/agent-gateway-gateway:1.0.34
```

Use the digest only when it matches the publisher's trusted release record.
The tag-to-digest result from a registry by itself does not prove who
published the image.

## 2. Verify the publisher signature

Install Cosign from its official distribution channel. For keyless signing,
the publisher must publish the exact certificate identity and OIDC issuer
that signed the release. Set those published values and verify the
digest-pinned image:

```bash
IMAGE='docker.io/stevef1uk/agent-gateway-gateway@sha256:<published-digest>'
SIGNER_ID='<exact-certificate-identity-published-by-Agent-Gateway>'
OIDC_ISSUER='<OIDC-issuer-published-by-Agent-Gateway>'

cosign verify \
  --certificate-identity "$SIGNER_ID" \
  --certificate-oidc-issuer "$OIDC_ISSUER" \
  "$IMAGE"
```

If the publisher instead distributes a public key and its fingerprint through
a trusted channel, verify with that key:

```bash
cosign verify --key /path/to/publisher-cosign.pub "$IMAGE"
```

Do not guess the signer identity or trust an identity copied from the
registry. A verification failure means stop: check the digest and trusted
signing information before running the image.

**Current status:** this repository does not currently document an
authenticated Cosign signer identity or signatures for the image releases.
The values above are placeholders, not working credentials. Until the
publisher provides trusted signer information and signatures for a release,
users cannot establish publisher authenticity with Cosign.

## 3. Verify optional attestations

An SBOM or provenance statement is a separate signed attestation attached to
an image digest. Verify it against the same trusted signer information and
the exact digest:

```bash
cosign verify-attestation \
  --certificate-identity "$SIGNER_ID" \
  --certificate-oidc-issuer "$OIDC_ISSUER" \
  --type spdxjson \
  "$IMAGE"
```

For SLSA provenance v1, use:

```bash
cosign verify-attestation \
  --certificate-identity "$SIGNER_ID" \
  --certificate-oidc-issuer "$OIDC_ISSUER" \
  --type https://slsa.dev/provenance/v1 \
  "$IMAGE"
```

After verification, inspect the statement's subject digest and ensure it
matches the image you intend to run. Check the source repository, resolved
commit, builder and build type in provenance. A provenance statement added
after a build is a signed publisher assertion, not independently observed
build evidence and not proof of a SLSA level.

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

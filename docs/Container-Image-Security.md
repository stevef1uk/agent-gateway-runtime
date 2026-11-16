# Verifying Agent Gateway container images

This guide covers Cosign signatures for the existing Docker Hub images used by
the `main` branch's Docker Compose stack. The Compose file currently references
five Agent Gateway images; its version tags are listed in
[`demo/docker-compose.yml`](../demo/docker-compose.yml).

## What a signature proves

A Cosign signature binds a trusted signer to an image digest. If a tag is
moved to different content, that content has a different digest and will not
pass verification under the old signature. Always verify an immutable
`repository@sha256:...` reference when possible; a tag alone can move.

Cosign signatures are separate registry artifacts. Signing these existing
images does not rebuild or modify them, so it does not change the image digest
or how the containers run. Cosign signing credentials are also separate from
the application's licence, encryption, or decryption keys. Do not change
application keys as part of this signing process.

A valid signature establishes that the trusted signer approved the digest. It
does not prove that the image is safe, that its source is correct, or that a
specific build process produced it. A signed licence token is not an image
signature and does not authenticate the publisher or image contents.

## Sign the existing Compose images

The repository includes a manually triggered, signing-only workflow at
[`sign-main-compose-images.yml`](../.github/workflows/sign-main-compose-images.yml).
It resolves each Compose tag to a digest and signs that digest. It does not
build or push image layers.

Before running it:

1. In GitHub repository settings, create an environment named
   `image-signing`. Require a reviewer for deployments to that environment.
2. Add environment secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`. Use a
   Docker Hub access token with write permission limited to the five
   `stevef1uk/agent-gateway-*` repositories listed in the workflow. The token
   is used only to publish signature artifacts to Docker Hub; it is not an
   image build or application key.
3. In **Actions**, select **Sign main Compose images**, choose the `main`
   branch, and run the workflow. Review and approve the environment deployment.

The workflow requests a short-lived GitHub OIDC identity for Cosign keyless
signing. The expected certificate identity is:

```text
https://github.com/stevef1uk/agent-gateway-runtime/.github/workflows/sign-main-compose-images.yml@refs/heads/main
```

The OIDC issuer is:

```text
https://token.actions.githubusercontent.com
```

The workflow records the exact signed digests in its run summary. Treat those
digests as the release references; do not rely on a tag alone.
Adding this workflow does not itself publish any signatures: the environment
and Docker Hub secrets must be configured and an authorized run must complete.

## Verify signatures

Install Cosign from its official distribution channel. For each digest shown
in the workflow summary, run:

```bash
IMAGE='docker.io/stevef1uk/agent-gateway-gateway@sha256:<digest-from-workflow-summary>'

cosign verify \
  --certificate-identity 'https://github.com/stevef1uk/agent-gateway-runtime/.github/workflows/sign-main-compose-images.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  "$IMAGE"
```

Repeat with each image digest you use. Verification failure means you must
stop and check the digest and signer identity; do not deploy an unverified
replacement. The verification identity and issuer must be obtained from this
trusted release documentation, not copied from an untrusted image or registry
response.

Verification of these public images does not require Docker Hub login. Docker
Hub credentials are required only by the publisher workflow to upload the
signature artifacts.

To check the Compose demo, run it as usual after verifying the images:

```bash
cd demo
docker compose pull
docker compose up -d
docker compose ps
```

Signing does not affect Compose behavior. This runtime check is separate from
cryptographic verification and does not establish that the images are
vulnerability-free. Compose currently refers to version tags, so compare each
tag's resolved digest with the signed digest in the workflow summary before
pulling. If a tag has moved, do not run Compose expecting the signature check
to protect the replacement; pin the Compose image to the verified digest first.

## SBOMs and provenance

An SBOM can be generated from an existing image with Syft and attached to its
digest; this does not require rebuilding. For example:

```bash
IMAGE='docker.io/stevef1uk/agent-gateway-gateway@sha256:<digest>'
syft "$IMAGE" -o spdx-json > sbom.spdx.json
cosign attest --yes --type spdxjson --predicate sbom.spdx.json "$IMAGE"
```

Verify the SBOM attestation with `cosign verify-attestation --type spdxjson`
and the exact certificate identity and OIDC issuer of the identity that
attached it:

```bash
cosign verify-attestation \
  --certificate-identity '<exact-identity-that-attested-the-sbom>' \
  --certificate-oidc-issuer '<issuer-that-issued-that-identity>' \
  --type spdxjson \
  "$IMAGE"
```

The signing workflow in this repository currently signs images only; it does
not generate or attach SBOMs. A locally generated SBOM attestation would be
signed by the local keyless identity, not by the GitHub Actions workflow
identity above. Publish that exact attester identity for consumers to verify.
`syft` is not required for signing or verifying image signatures. A local
Buildx builder is likewise not needed for either operation; Buildx is used by
the signing workflow only to resolve the registry tag to its immutable digest.

Do not attach provenance until the exact source repository and full commit for
each image are confirmed from trustworthy build/release records. A tag name,
current branch tip, or nearby commit is not sufficient. Provenance added
after a build is a signed publisher assertion, not observed build evidence,
and must be labeled as retrospective.

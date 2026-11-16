# Verifying GCP container images

The Docker Hub images for release `2026-11-15-sec1` below were signed by the
Agent Gateway GCP image-signing workflow and independently verified on
2026-11-16. Emotion is optional; gateway and web are the standard services.
Other versions or overrides require verification of their own digests.

Install [Cosign](https://docs.sigstore.dev/cosign/system_config/installation/)
and run the following in Bash:

```bash
set -euo pipefail
SIGNER_ID='https://github.com/stevef1uk/agent-gateway/.github/workflows/sign-gcp-images.yml@refs/heads/gcp'
OIDC_ISSUER='https://token.actions.githubusercontent.com'
images=(
  docker.io/stevef1uk/agent-gateway-gateway_g@sha256:c8e9ceecbc7dd2feb6e2f99bcedb69091b9221372a14356f67bfa2513b67bbd0
  docker.io/stevef1uk/agent-gateway-web_g@sha256:b9fcfc31288c6354a833ffd9d4e3acea422dbe88960bad61651e66aa9c060827
  docker.io/stevef1uk/agent-gateway-emotion_g@sha256:6ca2d6bb3bdeccbbea5217a421423b031627f31d2bce04cef1586831f7b3aaae
)
for image in "${images[@]}"; do
  cosign verify --certificate-identity "$SIGNER_ID" \
    --certificate-oidc-issuer "$OIDC_ISSUER" "$image"
done
```

Verification establishes that the specified GitHub Actions identity signed
the exact digest; it does not prove a source commit, build provenance, or
absence of vulnerabilities. A licence signature is separate from an image
signature. These signatures do not establish an SBOM or provenance
attestation. Stop if verification fails.

These are Docker Hub **source** images. The deployment normally rebuilds
images into Artifact Registry with Cloud Build and deploys a tag; the resulting
digest and signatures may differ. The deployment does not automatically
enforce Cosign verification. Verify source images and separately verify
destination artifacts according to your deployment policy; an existing
Artifact Registry image or a mutable tag may refer to different content.

# Verifying AWS container images

The Docker Hub image digests below were signed by the Agent Gateway AWS
image-signing workflow and independently verified on 2026-11-16. They match
the AWS release manifest at commit
`c3f4363751a75b255ee72fe745b72df2b86e0457`. Check the
[current release manifest](../releases/current.json) before deploying:
new releases or image overrides require verification of their own digests.

Install [Cosign](https://docs.sigstore.dev/cosign/system_config/installation/)
and run the following in Bash:

```bash
set -euo pipefail
SIGNER_ID='https://github.com/stevef1uk/agent-gateway/.github/workflows/sign-aws-images.yml@refs/heads/aws'
OIDC_ISSUER='https://token.actions.githubusercontent.com'
images=(
  docker.io/stevef1uk/agent-gateway-authz_l@sha256:417f1a0c24716a89a422e32a99d6b63ebcf3efcf05bd760ad5091639083a6d16
  docker.io/stevef1uk/agent-gateway-tokensvc_l@sha256:ee9fe98275a34df427fcfbe9a4473944fde87418a083e850972c7a30b56cc342
  docker.io/stevef1uk/agent-gateway-gateway_l@sha256:06634698048c68ad67c9ba1a43d260caaf4f50b68ed0ef8458d4f738003f7c43
  docker.io/stevef1uk/agent-gateway-web_l@sha256:d742d6e421c7ce0a35902fe17b5ef37392feb5473c1116eec84a6c1b4e42345e
  docker.io/stevef1uk/agent-gateway-emotion_l@sha256:2c298958c356e92d62d66831dbd3889fa0105ffbd45a0c118ca41e9043c2fce8
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

These are Docker Hub **source** images. The deployment copies images to
ECR; do not assume an ECR copy carries the Docker Hub signature or retains
the same digest. The deployment does not automatically enforce Cosign
verification. Verify the source images and separately verify any destination
artifacts or overrides according to your deployment policy.

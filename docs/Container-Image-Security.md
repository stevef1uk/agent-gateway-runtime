# Verifying Azure container images

The Docker Hub image digests below were signed by the Agent Gateway Azure
image-signing workflow and independently verified on 2026-11-16. They match
the example configuration at commit
`56b0bcdac9c4d89d030f4a28e44de40bbf22c9d3`. Check the
[current example configuration](../deploy/azure/azure-config.example.json)
before deploying: new releases or image overrides require verification of
their own digests.

Install [Cosign](https://docs.sigstore.dev/cosign/system_config/installation/)
and run the following in Bash:

```bash
set -euo pipefail
SIGNER_ID='https://github.com/stevef1uk/agent-gateway/.github/workflows/sign-azure-images.yml@refs/heads/azure'
OIDC_ISSUER='https://token.actions.githubusercontent.com'
images=(
  docker.io/stevef1uk/agent-gateway-authz_azure@sha256:01f6f35c031494b62d57b9238755a6bf6a18bad94c5ffaf944678d92b8064678
  docker.io/stevef1uk/agent-gateway-tokensvc_azure@sha256:3c23d18c93a51d695a21e9eea93dc9f233889477089590e0a8651f6214ff05d3
  docker.io/stevef1uk/agent-gateway-gateway_azure@sha256:7060fa938a844e101788344afaf3c71b59447b43e3a96c3a3cfbffb42c37dfec
  docker.io/stevef1uk/agent-gateway-web_azure@sha256:d49400026762e34bc025e03e286896e32ad3b1f100b2dba1ae733c94c7a71f38
  docker.io/stevef1uk/agent-gateway-emotion_azure@sha256:986f4d08cd28a978ad9109b68c5f9e2add4aad8b0af5c75d80c86531a52c0075
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

These signatures cover the listed Docker Hub images. Images copied to another
registry or supplied through an override must be checked separately. The
deployment does not automatically enforce Cosign verification.

#!/usr/bin/env bash
set -uo pipefail

SIGNER_ID='https://github.com/stevef1uk/agent-gateway/.github/workflows/sign-main-images.yml@refs/heads/main'
OIDC_ISSUER='https://token.actions.githubusercontent.com'
images=(
  docker.io/stevef1uk/agent-gateway-authz@sha256:a0ce26b4f5fabae96e084d15b9777c4a730c6e530c1c4e5393e7ea170b22357f
  docker.io/stevef1uk/agent-gateway-tokensvc@sha256:e62ede0ee3a8308ccc5a060d95b9b2159f34b653b56514f3102833a8b5faff1c
  docker.io/stevef1uk/agent-gateway-gateway@sha256:2dce006ce0b53bdeb57525b3d993809fbc802a24e1dcfd39e46dde1a4ee72ce8
  docker.io/stevef1uk/agent-gateway-web@sha256:12c13a7240547ed43b7cd84c37d24b751d29a0b1eef5f3fb0095acd3b9f0cc4d
)

if ! command -v cosign >/dev/null 2>&1; then
  printf 'Error: cosign is not installed or is not on PATH.\n' >&2
  exit 127
fi

failed=0
for image in "${images[@]}"; do
  printf '\nVerifying %s\n' "$image"
  if cosign verify \
    --certificate-identity "$SIGNER_ID" \
    --certificate-oidc-issuer "$OIDC_ISSUER" \
    "$image"; then
    printf 'PASS: %s\n' "$image"
  else
    status=$?
    printf 'FAIL (exit %d): %s\n' "$status" "$image" >&2
    failed=1
  fi
done

if (( failed )); then
  printf '\nOne or more image signatures could not be verified.\n' >&2
  exit 1
fi

printf '\nAll four image signatures verified successfully.\n'

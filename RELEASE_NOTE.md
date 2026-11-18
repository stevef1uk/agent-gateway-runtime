# Main image release notes

**Release date:** 2026-11-18

**Image versions:** Authz `1.0.16`, TokenSvc `1.0.10`, Gateway `1.0.36`, Web `1.0.61`

This release refreshes the four public main images. The Web image contains the
Policy Playground fix; the other three services have no application behavior
change in this image refresh. All four images are multi-platform and include
BuildKit SBOM and provenance attestations. Each image digest is signed with
keyless Cosign through the main-branch GitHub Actions workflow. The
[signing workflow run](https://github.com/stevef1uk/agent-gateway/actions/runs/44258495064)
completed successfully.

## Main image change

- The Policy Playground now stores the signed-in owner of its probe
  delegation separately from the current session subject. On identity changes,
  it clears a delegation and comparison baseline if the owner does not match
  (including older saved state that did not record an owner), then asks the
  user to create a fresh delegation. A delegation belonging to the current
  user is preserved.
- Added an E2E regression case for clearing a legacy cached delegation after
  an identity switch.

## Demo, policy, and deployment changes

- The demo Compose API Wizard examples route through dedicated policy
  enforcement gateways to their intended upstream services.
- The OPA demo policy validates spend amounts and counts as non-negative
  integers, gives explicit reasons for invalid values, and compares numeric
  values consistently when API inputs are strings or numbers.
- Demo instructions now distinguish the local Dex fixture from hardened
  Google and Microsoft sign-in, document tunnel callback setup, and explain
  how to combine OPA and egress overlays.
- Demo scripts and guides were corrected and expanded for Go proxy,
  OpenShell/OpenClaw, OAuth, FreeRide, environment variables, and teardown.
- K3s examples no longer embed reusable JWT/admin credentials. Secret
  creation, tenant onboarding, smoke checks, and their documentation use
  generated credentials and the current secret workflow.
- Compose host ports are loopback-bound except for the documented Docker
  bridge listener needed by container-based testing.
- Added image verification instructions that distinguish publisher
  signatures, SBOM/provenance attestations, and secure-packager runtime keys.
- Corrected approval-expiry guidance to state that the current main gateway
  image does not honor `APPROVAL_TTL`; the pilot requires a supporting build.

## Published images and verification

The table below records the multi-platform OCI index digests for the versioned
main images. Compose pins these immutable digests. The `latest` aliases were
updated after signing and resolve to the same digests.

| Service | Version | OCI index digest |
|---|---|---|
| Authz | `1.0.16` | `sha256:a0ce26b4f5fabae96e084d15b9777c4a730c6e530c1c4e5393e7ea170b22357f` |
| TokenSvc | `1.0.10` | `sha256:e62ede0ee3a8308ccc5a060d95b9b2159f34b653b56514f3102833a8b5faff1c` |
| Gateway | `1.0.36` | `sha256:2dce006ce0b53bdeb57525b3d993809fbc802a24e1dcfd39e46dde1a4ee72ce8` |
| Web | `1.0.61` | `sha256:12c13a7240547ed43b7cd84c37d24b751d29a0b1eef5f3fb0095acd3b9f0cc4d` |

BuildKit attaches SPDX SBOM and SLSA provenance attestations to each image
index. Cosign signs the complete OCI index digest, including its attestation
descriptors. The signatures use this identity:

```text
https://github.com/stevef1uk/agent-gateway/.github/workflows/sign-main-images.yml@refs/heads/main
```

with OIDC issuer:

```text
https://token.actions.githubusercontent.com
```

To re-verify the signatures, run `./verify-images.sh` from the repository
root. See [Container Image Security](docs/Container-Image-Security.md) for the
full digest and SBOM verification steps.

The image refresh does not include managed-tier (`_m`), AWS (`_l`), Azure
(`_azure`), or GCP (`_g`) image streams.

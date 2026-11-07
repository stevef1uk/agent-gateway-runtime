# Self-host Agent Gateway on AWS

This is the alternative to using a demo hosted by the operator. **The first AWS
application deployment/acceptance run is still pending, and a third-party deployment
bundle has not been published.** There is no anonymous one-command installer or
Marketplace listing to download today. Do not use the `main` branch's Docker/Dex
or Kubernetes instructions as a substitute.

## Marketplace delivery

This is also an intended Marketplace delivery scenario, subject to the supported
fulfillment route and seller review. See [AWS Marketplace](AWS-Marketplace.md).
An approved listing and subscription cannot be inferred from the development ZIPs.

## What you will need

- Your own AWS account, billing notifications and reviewed deployment/cleanup permissions.
- A compatible operator-supplied release: four ARM64 Lambda ZIPs, CloudFormation
  templates, release checksums, deployment instructions and a scoped teardown tool.
- A unique Cognito login-domain prefix and an operator email you control.
- The weather upstream `https://api.open-meteo.com` for this personal evaluation.
- The software rights/licence supplied with that release. This demo repository's
  licence does not grant a licence to private implementation binaries/source.

Ordinary demo users do not need private source access. Self-hosting must become
independent of that access through a published and AWS-tested release bundle. Until
that bundle is supplied, the self-hosting path is a documented preview; ask the
operator for a compatible evaluation release rather than guessing download URLs.

## Deployment sequence once a release is available

1. Verify the release checksums and licence. Read its cost assumptions and cleanup
   permissions before creating anything.
2. Check the AWS CLI identity is your intended account and region. A validation-only
   profile is not enough; do not bypass permission errors with an unrelated root session.
3. Review/deploy the private artifact-store template, then upload ZIPs under an
   immutable release prefix. Never overwrite a release key.
4. Prepare/review the application change set with weather mode enabled. The upstream
   must be exactly `https://api.open-meteo.com`; only three exact weather routes are added.
5. Deploy the approved change set, invite your Cognito operator and complete sign-in.
6. Save the release's teardown inventory. Verify public health/discovery, unsigned
   internal-route denial and normal signed console operations.
7. Follow [the weather walkthrough](Public-API-Curl-Tutorial.md). Test allow, denial,
   one-use approval, audit and revocation before treating the release as accepted.
8. Stop the disposable stack when finished. Choose explicitly whether to retain data
   or permanently purge tables/users/keys/logs/artifact versions.

The development design is four buffered ARM64 Lambda services, five HTTP APIs,
DynamoDB shared state, Cognito, generated-secret references, logs and a versioned
private S3 artifact bucket. It has no always-on VM, NAT, RDS or Redis baseline.
It is not full-feature production HA: see [architecture limitations](Architecture.md).

## Costs and teardown

A $10 AWS Budget is an alerting target, not a hard spending cap. Your account's
actual usage, log/storage growth and slow upstream requests determine the bill.
Review [pricing](Pricing.md). Deleting the stacks can retain billable data/secrets;
a full purge is separate and irreversible. The published release must include its
own tested cleanup tool before self-hosting is presented as ready for third parties.
There is no account-wide deletion or automatic budget-triggered purge in this repo.

## For release operators

The implementation currently exists in the separate authorized source repository.
Its working release lineage starts at `c7e0906` on `aws`. The operator reference
[deployment notes](Deployment-Guide.md) link to source guides and are not a
requirement for hosted-demo users. Before releasing self-hosting publicly, complete
real AWS deployment/cleanup acceptance and publish an appropriately licensed,
versioned artifact/template/checksum/teardown bundle. No bundle availability or
managed-service acceptance is implied by the local test results in this repository.

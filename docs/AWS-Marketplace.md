# AWS Marketplace delivery

AWS Marketplace is an intended purchase/distribution channel for Agent Gateway.
**No listing, offer, product ID, Marketplace entitlement integration or subscriber
onboarding is implemented or published yet.** Do not subscribe to an unrelated
product or infer a subscription from this repository's demo access.

## What buyers should eventually receive

| Deployment choice | Intended buyer experience | Current status |
| --- | --- | --- |
| Hosted service | Subscribe through an approved SaaS listing, complete account/tenant onboarding, receive a console/gateway endpoint and run the weather demo | Proposed; no published listing, billing/entitlement integration or hosted AWS acceptance yet |
| Customer's own AWS account | Receive the approved fulfillment instructions/artifacts, review IAM/cost/change sets, deploy and run the same weather demo | Technical development templates exist; customer bundle and Marketplace fulfillment route are not released/validated |

The same weather walkthrough should work after either deployment supplies compatible
ConsoleURL/GatewayURL values and a Cognito invitation. Marketplace billing and
entitlements must not be replaced by a shared demo token, a downloaded source ZIP
or an assumption that the customer has a subscription.

## Hosted offer

AWS documents SaaS products where the seller hosts the service and manages customer
access, accounts and provisioning. A real offer needs the selected Marketplace
pricing model, registration/onboarding, entitlement/subscription lifecycle and any
required metering. Cancellation/expiry must have defined service behavior. A demo
login or existing image licence alone does not implement this.

## Self-hosted offer

The current core is a buffered Lambda/DynamoDB development stack. Its CloudFormation
and Lambda ZIP format is a technical installation format, not proof of an accepted
Marketplace product/delivery type. The seller must validate the supported fulfillment
arrangement with AWS before advertising a one-click listing or download.

SaaS Quick Launch can provision buyer-side resources for a SaaS offering. It should
not be described as automatically turning this entire self-hosted stack into an
approved standalone Lambda product. Container/AMI fulfillment are separate product
options with their own requirements; an optional proxy container does not by itself
approve distribution of the serverless core. No new always-on compute is being
added merely to claim Marketplace compatibility.

A released customer-account package must include appropriately licensed versioned
artifacts, checksums, supported-region/architecture instructions, IAM/cost review,
updates/rollback, acceptance evidence and scoped teardown with clear data-retention
behavior. See [Self-hosting](Self-Hosting.md). Private source access must not be a
prerequisite for ordinary third-party buyers.

## Charges and support

Published pricing must separate software/subscription charges from buyer AWS
infrastructure charges, paid upstream/API subscriptions and tax. There is no
Marketplace software price to quote today. Hosted-demo access does not imply a
paid subscription or service-level agreement. See [Pricing](Pricing.md) for current
infrastructure modeling and budget limitations.

Before publishing a listing, the offer must pass the selected AWS seller/release
process and real subscription/onboarding/entitlement/install/update/cancel/cleanup
acceptance, in addition to application security tests. Those results do not exist
yet. This page records intended delivery, not purchasing instructions for an
available product.

Official references: [SaaS products](https://docs.aws.amazon.com/marketplace/latest/userguide/saas-products.html),
[SaaS product creation](https://docs.aws.amazon.com/marketplace/latest/userguide/saas-create-product.html),
[SaaS Quick Launch](https://docs.aws.amazon.com/marketplace/latest/userguide/saas-product-settings.html),
[container delivery](https://docs.aws.amazon.com/marketplace/latest/userguide/container-based-products.html),
[metering/entitlement](https://docs.aws.amazon.com/marketplace/latest/userguide/saas-integration-metering-and-entitlement-apis.html).

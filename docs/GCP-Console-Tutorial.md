# GCP Console tutorial

This tutorial covers creating a delegation, selecting its policy engine, and
editing the deployment's shared Rego policy. Sign in with a Google account
listed in `--admin-emails`. The Rego editor is available only to allowlisted
administrators.

## Create a delegation and select Rego

1. Sign in to the GCP Console and open **API Wizard**.
2. Configure the API or MCP delegation and proceed to **Step 3: Delegation**.
3. Under **Authorization policy engine**, choose **Rego (OPA) policy**. The
   built-in policy is selected by default.
4. Complete the wizard and create the delegation. The delegation list shows
   which engine it uses.

This setting chooses the engine for that delegation; it does not edit the Rego
rules. New delegations without an explicit choice use the built-in policy.
Child delegations inherit their parent's engine. Both engines retain Gateway
scope checks and mandatory GCP approval rules.

## Edit and apply Rego

1. In the Console header, select **Manage Rego policy**.
2. The **Active Rego policy** editor loads the current policy. On a new
   deployment, this is the policy bundled with the Gateway image.
3. Edit the Rego source and select **Apply to the running engine**. The Gateway
   validates it with `opa check`. Invalid source is rejected; the previous
   valid policy remains active.
4. A successful save records the policy and administrator in Firestore.
   Gateway instances poll for updates and activate the new policy within about
   five seconds. The version history below the editor shows prior versions.

The policy is shared across the deployment. Every delegation whose engine is
Rego uses the latest active policy; selecting Rego on one delegation does not
create a separate policy copy for it. Delegations using the built-in policy
are unaffected by Rego rule changes.

## Restore a policy

- Select **Restore** beside a prior version in the version history to publish
  that content as a new version.
- Select **Restore initial policy** to restore the version bundled with the
  currently deployed Gateway image.
- Select **Reload latest** to discard unsaved editor changes and load the
  current Firestore version.

The editor keeps up to four previous versions for rollback. If another
administrator publishes while you are editing, your stale save is rejected;
reload the latest version before applying your changes.

## Verify a policy change

The policy page includes **Decision probes** for trying policy inputs against
the running authorization service:

1. Select **Create temporary probe delegation**. This creates a real,
   short-lived delegation scoped to `/orders` with a €200 spend cap; it expires
   after 30 minutes.
2. Edit the resource, action, or context JSON in each probe, then select
   **Run all probes**. The decisions reflect the active Rego policy and the
   probe delegation's scope and limits. These are authorization checks only:
   they do not call an upstream API or execute the action.
3. Change the Rego source and select **Apply**. The editor validates and saves
   the policy, then reruns the probes so you can see whether the decisions
   changed. For example, change the spend-cap rule and compare the probe with
   `{"amount":250}` before and after applying the policy.

### Changing the spend approval threshold

By default, `spend_breached` compares the request amount with the
delegation's `spend_per_order.max`. To set a per-delegation threshold, update
the spend limit in the API Wizard. To hard-code a deployment-wide threshold
of 250 in Rego, change the comparison inside `spend_breached` from
`num(input.action.context.amount) > num(l.max)` to
`num(input.action.context.amount) > 250`. Also update the message in
`assessment_reason` to say `fixed approval threshold 250`; otherwise the
decision reason will still display the delegation's configured limit.

The comparison is strictly greater than: amount 250 does not require approval,
while 251 does. Use `{"amount":251}` in a decision probe to check the new
threshold. Rego is shared across the deployment, so a hard-coded change
affects all Rego-enabled delegations; use the Wizard's spend limit when
different delegations need different thresholds.

You can also use the Console's API tester or a client with a delegation token
to check a request covered by a Rego-enabled delegation.

Policy edits are deployment-wide, so review the impact on all Rego-enabled
delegations before applying a change. Keep changes small and use version
history to roll back if observed decisions are not as expected.

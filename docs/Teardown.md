# Finish a hosted demo or remove your own deployment

## Hosted-demo user

Revoke your test delegation in the console, clear the token from your shell/browser
and sign out. You do not need an AWS cleanup profile and must not attempt to delete
the operator's shared deployment. Ask the operator to stop a dedicated test instance
when appropriate. The client script never deletes AWS resources.

## Self-hosting customer

Use the cleanup tool supplied with your compatible deployment release. That bundle
has not been published yet: see [Self-hosting](Self-Hosting.md). It must distinguish
stack removal (retaining data) from permanent purge of billable retained data, verify
your account/stack ownership, save an inventory and handle partial failures. Do not
use broad account-wide deletion or the `main` branch's Docker cleanup commands.

A billing budget is not a hard spending cap. Retained secrets/data/artifact versions
can keep costing money; stop load generators before cleaning up. No automatic
budget-triggered deletion is installed by this repository.

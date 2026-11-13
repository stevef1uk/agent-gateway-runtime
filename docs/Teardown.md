# Remove your AWS test deployment

## Hosted/shared deployment user

Revoke disposable delegations, clear exported agent tokens, and sign out. Ask the deployment owner to manage resources. Do not delete a shared installation with your testing credentials.

## Customer-owned deployment

Run from your runtime `aws` checkout with the same `aws-config.mk` used to deploy. Stop generating calls and stop others from provisioning new demos while cleanup runs. Keep the local `dist/aws-lambda/teardown/` inventory for partial-run recovery. The account confirmation must match `AWS_ACCOUNT` in your local config; `make aws-identity` verifies the match without printing the account number.

The cleanup ownership check reads the parent DynamoDB catalogue and passes the fixed demo-deployer role to CloudFormation when deleting child stacks. If cleanup reports `dynamodb:GetItem` or `iam:PassRole` `AccessDenied`, the administrator must update `agent-gateway-access-dev` with the current `deploy/aws/deployment-access.template.json` before retrying. Use a genuinely privileged administrator profile for that update; do not set `AWS_ADMIN_PROFILE` to the restricted `AWS_PROFILE` and do not grant the deployment role permissions manually.

1. If you created an optional proxy, delete it **before** shared services:
   ```bash
   make aws-proxy-delete
   ```
2. Delete a single owned demo if keeping the application:
   ```bash
   make aws-demo-delete DEMO=emotion CONFIRM_ACCOUNT=YOUR_ACTUAL_ACCOUNT
   ```
3. To delete all owned demo children then remove parent/artifact stacks while retaining their protected data:
   ```bash
   make aws-cleanup CONFIRM_ACCOUNT=YOUR_ACTUAL_ACCOUNT
   ```
   The helper reads the application's catalogue and validates stack names/account/ownership tags before deleting children. It does not scan/delete unrelated stacks. The parent cleanup tool verifies its inventory/ownership and waits for deletion. Retained DynamoDB, Cognito, secrets, logs and artifact versions may still incur charges.
4. Only if you deliberately want to permanently purge retained test data:
   ```bash
   make aws-cleanup CONFIRM_ACCOUNT=YOUR_ACTUAL_ACCOUNT PURGE_DATA=1
   ```
   This is irreversible. Review the cleanup inventory and retain any required records first. If the parent was already deleted, use the saved inventory with the direct cleanup tool rather than bypassing catalogue validation:
   ```bash
   python3 scripts/teardown-aws-deployment.py --help
   ```
   Supply the same profile, account, stack names and saved state-file shown in your inventory. The script defaults to a read-only plan unless `--execute` and matching `--confirm-account` are supplied.
5. After all functions/stacks using the images are removed, optionally delete this application's five private ECR repositories:
   ```bash
   make aws-ecr-cleanup CONFIRM_ACCOUNT=YOUR_ACTUAL_ACCOUNT
   ```
6. Administrator access is last:
   ```bash
   make aws-access-delete CONFIRM_ACCOUNT=YOUR_ACTUAL_ACCOUNT
   ```
   This uses the explicit administrator profile in your configuration. Do not remove the workload boundary while execution roles still depend on it.

Replace `YOUR_ACTUAL_ACCOUNT` with the account number you confirmed; do not use a vendor example account. You can first run the direct teardown tool without `--execute` to inspect its plan. `make aws-cleanup` executes deletion and is not a plan.

These commands do not delete customer-created OpenClaw/backend hosts, disks, snapshots or networking. Manage those through their own provisioning procedure. Review retained resources and billing after cleanup; a budget is not an automatic spending cap.

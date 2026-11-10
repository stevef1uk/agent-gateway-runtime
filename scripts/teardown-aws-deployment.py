#!/usr/bin/env python3
"""Plan or remove only the two Agent Gateway development stacks and their retained resources.

AWS CLI + Python standard library only. Default is an AWS-read-only plan. No
credentials or secret values are saved. Keep the inventory to resume a partial run.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


class TeardownError(RuntimeError):
    pass


class AWS:
    def __init__(self, profile, region):
        self.prefix = ["aws", "--profile", profile, "--region", region, "--no-cli-pager", "--output", "json"]

    def call(self, service, operation, params=None, missing_ok=False, no_paginate=False):
        args = self.prefix + [service, operation]
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json") as handle:
            if params:
                json.dump(params, handle)
                handle.flush()
                args += ["--cli-input-json", "file://" + handle.name]
            if no_paginate:
                args.append("--no-paginate")
            result = subprocess.run(args, capture_output=True, text=True, check=False)
        if result.returncode:
            missing = re.search(r"\((NoSuchBucket|ResourceNotFoundException|ResourceNotFound|NoSuchEntity)\)", result.stderr)
            absent_stack = service == "cloudformation" and "(ValidationError)" in result.stderr and "does not exist" in result.stderr
            if missing_ok and (missing or absent_stack):
                return None
            raise TeardownError(f"{service} {operation} failed: {result.stderr.strip()}")
        return json.loads(result.stdout) if result.stdout.strip() else {}

    def wait(self, service, waiter, params):
        args = self.prefix + [service, "wait", waiter]
        for key, value in params.items():
            args += ["--" + key, value]
        result = subprocess.run(args, capture_output=True, text=True, check=False)
        if result.returncode:
            raise TeardownError(f"{service} wait {waiter} failed: {result.stderr.strip()}")

    def pool_update_fields(self):
        result = subprocess.run(self.prefix + ["cognito-idp", "update-user-pool", "--generate-cli-skeleton", "input"], capture_output=True, text=True, check=False)
        if result.returncode:
            raise TeardownError("Cannot determine Cognito update input schema; pool left unchanged")
        return json.loads(result.stdout)


PURGE_TYPES = {"AWS::DynamoDB::Table", "AWS::Logs::LogGroup", "AWS::SecretsManager::Secret", "AWS::Cognito::UserPool", "AWS::S3::Bucket"}


def save_inventory(path, inventory):
    path.parent.mkdir(parents=True, exist_ok=True)
    # Atomic replacement leaves the last usable inventory if a run is interrupted.
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as handle:
        json.dump(inventory, handle, indent=2)
        handle.write("\n")
        temporary = Path(handle.name)
    temporary.replace(path)


def stack_record(aws, name):
    response = aws.call("cloudformation", "describe-stacks", {"StackName": name}, missing_ok=True)
    if response is None:
        return None
    stack = response["Stacks"][0]
    if stack["StackStatus"] == "DELETE_COMPLETE":
        return None
    if stack["StackStatus"].endswith("_IN_PROGRESS") and stack["StackStatus"] != "REVIEW_IN_PROGRESS":
        raise TeardownError(f"{name} is {stack['StackStatus']}; wait for the operation to finish before teardown")
    template = aws.call("cloudformation", "get-template", {"StackName": stack["StackId"], "TemplateStage": "Original"})["TemplateBody"]
    if isinstance(template, str):
        template = json.loads(template)
    resources = template.get("Resources", {})
    if not ("GatewayFunction" in resources and "WebFunction" in resources) and not ("Artifacts" in resources and "HTTPSOnly" in resources):
        raise TeardownError(f"{name} is not a recognized Agent Gateway stack")
    summaries = aws.call("cloudformation", "list-stack-resources", {"StackName": stack["StackId"]})["StackResourceSummaries"]
    retained = []
    for item in summaries:
        declaration = resources.get(item["LogicalResourceId"], {})
        if declaration.get("DeletionPolicy") == "Retain" and item.get("PhysicalResourceId"):
            retained.append({"logical_id": item["LogicalResourceId"], "type": item["ResourceType"], "id": item["PhysicalResourceId"]})
    return {"name": name, "stack_id": stack["StackId"], "retained": retained}


def verify_record(aws, record, account, region):
    prefix = f"arn:aws:cloudformation:{region}:{account}:stack/{record['name']}/"
    if not record["stack_id"].startswith(prefix):
        raise TeardownError("Inventory stack identity does not match the selected account/region/name")
    # CloudFormation keeps deleted-stack resource history for up to 90 days.
    # Never trust an edited local manifest as the only authority for direct deletion.
    history = aws.call("cloudformation", "list-stack-resources", {"StackName": record["stack_id"]})["StackResourceSummaries"]
    known = {(r["LogicalResourceId"], r["ResourceType"], r.get("PhysicalResourceId")) for r in history}
    for resource in record["retained"]:
        if (resource["logical_id"], resource["type"], resource["id"]) not in known:
            raise TeardownError("Retained resource does not match CloudFormation history; manual ownership review required")
        if resource["type"] not in PURGE_TYPES:
            raise TeardownError(f"Unsupported retained type {resource['type']}; refusing automatic purge")


def empty_bucket(aws, bucket, account):
    owner = {"Bucket": bucket, "ExpectedBucketOwner": account}
    # Incomplete multipart uploads also consume storage, independently of versions.
    while True:
        result = aws.call("s3api", "list-multipart-uploads", dict(owner, MaxUploads=1000), missing_ok=True, no_paginate=True)
        if result is None:
            return False
        uploads = result.get("Uploads", [])
        if not uploads:
            break
        for upload in uploads:
            aws.call("s3api", "abort-multipart-upload", dict(owner, Key=upload["Key"], UploadId=upload["UploadId"]))
    # Repeatedly delete the first page; no continuation token can skip a deleted page.
    while True:
        result = aws.call("s3api", "list-object-versions", dict(owner, MaxKeys=1000), missing_ok=True, no_paginate=True)
        if result is None:
            return False
        objects = [{"Key": item["Key"], "VersionId": item["VersionId"]} for item in result.get("Versions", []) + result.get("DeleteMarkers", [])]
        if not objects:
            break
        response = aws.call("s3api", "delete-objects", dict(owner, Delete={"Objects": objects, "Quiet": True}))
        if response.get("Errors"):
            raise TeardownError("S3 reported per-object deletion errors; bucket was not declared empty")
    return True


def purge_resource(aws, resource, account):
    kind, physical = resource["type"], resource["id"]
    if kind == "AWS::DynamoDB::Table":
        if aws.call("dynamodb", "delete-table", {"TableName": physical}, missing_ok=True) is not None:
            aws.wait("dynamodb", "table-not-exists", {"table-name": physical})
    elif kind == "AWS::Logs::LogGroup":
        aws.call("logs", "delete-log-group", {"logGroupName": physical}, missing_ok=True)
    elif kind == "AWS::SecretsManager::Secret":
        aws.call("secretsmanager", "delete-secret", {"SecretId": physical, "ForceDeleteWithoutRecovery": True}, missing_ok=True)
    elif kind == "AWS::Cognito::UserPool":
        existing = aws.call("cognito-idp", "describe-user-pool", {"UserPoolId": physical}, missing_ok=True)
        if existing is not None:
            pool = existing["UserPool"]
            # Preserve supported configuration if disabling protection succeeds but
            # deletion later fails. Do not reset omitted fields to their defaults.
            fields = aws.pool_update_fields()
            update = {key: value for key, value in pool.items() if key in fields}
            update.update(UserPoolId=physical, DeletionProtection="INACTIVE")
            aws.call("cognito-idp", "update-user-pool", update)
            aws.call("cognito-idp", "delete-user-pool", {"UserPoolId": physical}, missing_ok=True)
    elif kind == "AWS::S3::Bucket":
        if empty_bucket(aws, physical, account):
            aws.call("s3api", "delete-bucket", {"Bucket": physical, "ExpectedBucketOwner": account}, missing_ok=True)
    else:
        raise TeardownError(f"Unsupported purge resource {kind}")


def run(args, aws):
    identity = aws.call("sts", "get-caller-identity")
    if identity["Account"] != args.account:
        raise TeardownError("AWS identity is in the wrong account; no changes made")
    if args.execute and args.confirm_account != args.account:
        raise TeardownError("Execution requires --confirm-account matching --account")
    inventory = {"account": args.account, "region": args.region, "stacks": []}
    if args.state_file.exists():
        inventory = json.loads(args.state_file.read_text())
        if inventory["account"] != args.account or inventory["region"] != args.region:
            raise TeardownError("Saved inventory belongs to a different account/region")
    names = [args.app_stack, args.artifact_stack]
    if any(record["name"] not in names for record in inventory["stacks"]):
        raise TeardownError("Inventory contains a stack outside the selected pair")
    live = []
    for name in names:
        found = stack_record(aws, name)
        saved = next((
            item for item in inventory["stacks"]
            if item["name"] == name and found and item["stack_id"] == found["stack_id"]
        ), None)
        if found:
            if saved:
                inventory["stacks"].remove(saved)
                # Preserve already-recorded retained objects after a partially failed deletion.
                known = {(r["type"], r["id"]) for r in found["retained"]}
                found["retained"] += [r for r in saved["retained"] if (r["type"], r["id"]) not in known]
            inventory["stacks"].append(found)
            live.append(found)
    for record in inventory["stacks"]:
        verify_record(aws, record, args.account, args.region)
    save_inventory(args.state_file, inventory)
    print(f"Account {args.account}; region {args.region}; inventory {args.state_file}")
    for record in inventory["stacks"]:
        print(f"Stack: {record['name']}")
        for resource in record["retained"]:
            print(f"  {'PURGE' if args.purge_data else 'RETAIN'} {resource['type']}: {resource['id']}")
    if not args.execute:
        print("PLAN ONLY: no AWS resources changed. Use --execute --confirm-account ACCOUNT to delete stacks.")
        return
    for record in sorted(live, key=lambda r: names.index(r["name"])):
        print(f"Deleting stack {record['name']} and waiting for completion...")
        aws.call("cloudformation", "delete-stack", {"StackName": record["stack_id"]}, missing_ok=True)
        aws.wait("cloudformation", "stack-delete-complete", {"stack-name": record["stack_id"]})
    if args.purge_data:
        # Verify authoritative history again after stack deletion, before direct deletion.
        for record in inventory["stacks"]:
            verify_record(aws, record, args.account, args.region)
            for resource in record["retained"]:
                print(f"Purging {resource['type']}: {resource['id']}")
                purge_resource(aws, resource, args.account)
        print("Stack deletion and retained-resource purge requests completed. AWS deletion/billing can settle asynchronously.")
    else:
        print("Stacks removed; retained tables, PITR, secrets, logs and artifact versions can STILL incur charges.")
    if not inventory["stacks"]:
        print("No matching live stacks or saved resources found. This does not audit older orphaned resources.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, help="Named, reviewed deployment/cleanup CLI profile")
    parser.add_argument("--account", required=True, help="Your 12-digit target account")
    parser.add_argument("--region", default="eu-west-3")
    parser.add_argument("--app-stack", default="agent-gateway-dev")
    parser.add_argument("--artifact-stack", default="agent-gateway-artifacts-dev")
    parser.add_argument("--state-file", type=Path)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--confirm-account")
    parser.add_argument("--purge-data", action="store_true", help="PERMANENTLY remove retained tables/users/secrets/logs and every artifact version")
    args = parser.parse_args()
    if not re.fullmatch(r"\d{12}", args.account):
        parser.error("account must have 12 digits")
    if args.app_stack == args.artifact_stack or any(not re.fullmatch(r"agent-gateway-[A-Za-z0-9-]+", name) for name in [args.app_stack, args.artifact_stack]):
        parser.error("use two distinct agent-gateway-* development stack names")
    if args.state_file is None:
        args.state_file = Path(__file__).resolve().parents[1] / "dist/aws-lambda/teardown" / f"{args.account}-{args.region}-{args.app_stack}-{args.artifact_stack}.json"
    try:
        run(args, AWS(args.profile, args.region))
    except (TeardownError, OSError, ValueError, KeyError) as exc:
        print(f"STOPPED: {exc}\nNo success assumed; keep the inventory, resolve the error and rerun.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

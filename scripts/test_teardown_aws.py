#!/usr/bin/env python3
"""Safety-contract tests using a fake AWS boundary; never contacts AWS."""
import argparse
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("teardown", Path(__file__).with_name("teardown-aws-deployment.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
ACCOUNT = "857710215813"
APP, ARTIFACT = "agent-gateway-dev", "agent-gateway-artifacts-dev"


class FakeAWS:
    def __init__(self):
        self.calls, self.deleted = [], set()
        self.versions, self.multipart = 0, False
        self.object_error = False
        self.resources = {
            APP: [("DomainState", "AWS::DynamoDB::Table", APP + "-domain"), ("JWTSecret", "AWS::SecretsManager::Secret", "secret-arn"), ("UserPool", "AWS::Cognito::UserPool", "eu-west-3_pool"), ("WebLog", "AWS::Logs::LogGroup", "/aws/lambda/" + APP + "-web")],
            ARTIFACT: [("Artifacts", "AWS::S3::Bucket", ARTIFACT + "-bucket")],
        }

    def call(self, service, operation, params=None, **kwargs):
        params = params or {}
        self.calls.append((service, operation, params))
        if service == "sts":
            return {"Account": ACCOUNT}
        if service == "cloudformation":
            name = params["StackName"].split("/")[1] if params["StackName"].startswith("arn:") else params["StackName"]
            if operation == "describe-stacks":
                return None if name in self.deleted else {"Stacks": [{"StackId": f"arn:aws:cloudformation:eu-west-3:{ACCOUNT}:stack/{name}/unique", "StackStatus": "CREATE_COMPLETE"}]}
            if operation == "get-template":
                resources = {logical: {"Type": kind, "DeletionPolicy": "Retain"} for logical, kind, _ in self.resources[name]}
                resources.update({"GatewayFunction": {}, "WebFunction": {}} if name == APP else {"HTTPSOnly": {}})
                return {"TemplateBody": {"Resources": resources}}
            if operation == "list-stack-resources":
                return {"StackResourceSummaries": [{"LogicalResourceId": logical, "ResourceType": kind, "PhysicalResourceId": physical} for logical, kind, physical in self.resources[name]]}
            if operation == "delete-stack":
                self.deleted.add(name)
                return {}
        if operation == "describe-user-pool":
            return {"UserPool": {"Id": "eu-west-3_pool", "DeletionProtection": "ACTIVE", "Policies": {"PasswordPolicy": {"MinimumLength": 14}}, "CreationDate": "read-only"}}
        if operation == "list-multipart-uploads":
            result = {"Uploads": [] if self.multipart else [{"Key": "unfinished", "UploadId": "upload"}]}
            self.multipart = True
            return result
        if operation == "list-object-versions":
            pages = [{"Versions": [{"Key": "release.zip", "VersionId": "v1"}, {"Key": "release.zip", "VersionId": "v2"}]}, {"DeleteMarkers": [{"Key": "release.zip", "VersionId": "marker"}]}, {}]
            return pages[min(self.versions, 2)]
        if operation == "delete-objects":
            self.versions += 1
            return {"Errors": [{"Code": "AccessDenied"}]} if self.object_error else {}
        if operation in ["delete-table", "delete-log-group", "delete-secret", "update-user-pool", "delete-user-pool", "abort-multipart-upload", "delete-bucket"]:
            return {}
        raise AssertionError((service, operation, params))

    def wait(self, service, waiter, params):
        self.calls.append((service, "wait " + waiter, params))

    def pool_update_fields(self):
        return {"UserPoolId": "", "DeletionProtection": "", "Policies": {}}


def arguments(path, execute=False, purge=False):
    return argparse.Namespace(profile="fake", account=ACCOUNT, region="eu-west-3", app_stack=APP, artifact_stack=ARTIFACT, state_file=path, execute=execute, confirm_account=ACCOUNT if execute else None, purge_data=purge)


class TeardownSafety(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "inventory.json"
        self.aws = FakeAWS()

    def run_tool(self, execute=False, purge=False):
        with contextlib.redirect_stdout(io.StringIO()):
            m.run(arguments(self.path, execute, purge), self.aws)

    def test_default_only_reads_and_saves_resumable_inventory(self):
        self.run_tool(purge=True)
        allowed = {"get-caller-identity", "describe-stacks", "get-template", "list-stack-resources"}
        self.assertTrue(all(operation in allowed for _, operation, _ in self.aws.calls))
        self.assertEqual(2, len(json.loads(self.path.read_text())["stacks"]))

    def test_delete_stacks_retains_data_and_deletes_application_first(self):
        self.run_tool(execute=True)
        deletes = [(service, operation, params) for service, operation, params in self.aws.calls if operation.startswith("delete-")]
        self.assertEqual(["delete-stack", "delete-stack"], [item[1] for item in deletes])
        self.assertIn("/" + APP + "/", deletes[0][2]["StackName"])

    def test_purge_after_partial_prior_run_uses_saved_history(self):
        self.run_tool(execute=True)
        self.aws.calls.clear()
        self.run_tool(execute=True, purge=True)
        operations = [operation for _, operation, _ in self.aws.calls]
        for operation in ["delete-table", "delete-log-group", "delete-secret", "update-user-pool", "delete-user-pool", "abort-multipart-upload", "delete-bucket"]:
            self.assertIn(operation, operations)
        batches = [params for _, operation, params in self.aws.calls if operation == "delete-objects"]
        self.assertEqual(2, len(batches))
        self.assertEqual("marker", batches[1]["Delete"]["Objects"][0]["VersionId"])
        self.assertTrue(all(params["ExpectedBucketOwner"] == ACCOUNT for params in batches))
        update = next(params for _, operation, params in self.aws.calls if operation == "update-user-pool")
        self.assertEqual(14, update["Policies"]["PasswordPolicy"]["MinimumLength"])
        self.assertNotIn("CreationDate", update)
        secret = next(params for _, operation, params in self.aws.calls if operation == "delete-secret")
        self.assertTrue(secret["ForceDeleteWithoutRecovery"])

    def test_wrong_account_or_missing_execution_confirmation_cannot_mutate(self):
        for field, value in [("account", "111111111111"), ("confirm_account", None)]:
            args = arguments(self.path, execute=True, purge=True)
            setattr(args, field, value)
            with self.assertRaises(m.TeardownError):
                m.run(args, self.aws)
            self.assertTrue(all(operation == "get-caller-identity" for _, operation, _ in self.aws.calls))

    def test_edited_inventory_cannot_select_unrelated_resources(self):
        self.run_tool()
        data = json.loads(self.path.read_text())
        data["stacks"][0]["retained"][0]["id"] = "unrelated-table"
        self.path.write_text(json.dumps(data))
        self.aws.deleted = {APP, ARTIFACT}
        with self.assertRaises(m.TeardownError):
            self.run_tool(execute=True, purge=True)
        self.assertFalse(any(operation.startswith("delete-") for _, operation, _ in self.aws.calls))

    def test_s3_per_object_error_stops_before_bucket_deletion(self):
        self.aws.object_error = True
        with self.assertRaises(m.TeardownError):
            m.empty_bucket(self.aws, "bucket", ACCOUNT)
        self.assertFalse(any(operation == "delete-bucket" for _, operation, _ in self.aws.calls))

    def test_access_denied_is_not_mistaken_for_already_deleted(self):
        denied = subprocess.CompletedProcess([], 254, "", "An error occurred (AccessDeniedException): denied")
        with patch.object(m.subprocess, "run", return_value=denied):
            with self.assertRaises(m.TeardownError):
                m.AWS("fake", "eu-west-3").call("dynamodb", "delete-table", {"TableName": "example"}, missing_ok=True)

    def test_unknown_retained_type_prevents_execution(self):
        self.aws.resources[APP].append(("Unknown", "AWS::Unknown::Data", "unknown"))
        with self.assertRaises(m.TeardownError):
            self.run_tool(execute=True, purge=True)
        self.assertFalse(any(operation.startswith("delete-") for _, operation, _ in self.aws.calls))


if __name__ == "__main__":
    unittest.main()

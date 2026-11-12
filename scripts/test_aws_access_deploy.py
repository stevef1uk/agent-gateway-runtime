#!/usr/bin/env python3
import importlib.util
import unittest
from unittest.mock import patch
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("access_deploy", ROOT / "scripts/aws-access-deploy.py")
access_deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(access_deploy)


class AccessDeploy(unittest.TestCase):
    def setUp(self):
        self.config = {
            "account": "123456789012",
            "stack": "agent-gateway-test",
            "bucket": "agent-gateway-artifacts-test-a1b2c3",
            "authz_url": "https://abc123.execute-api.eu-west-3.amazonaws.com",
            "gateway_licence_object": "activation/gateway.token",
        }

    def test_reads_exact_proxy_scope_from_parent_configuration(self):
        self.assertEqual(
            access_deploy.proxy_parameters(self.config, "123456789012", "agent-gateway-test"),
            ("agent-gateway-artifacts-test-a1b2c3", "abc123", "activation/gateway.token"),
        )

    def test_rejects_malformed_bucket_instead_of_emitting_invalid_parameter(self):
        self.config["bucket"] = "ProxyActivationBucket=agent-gateway-artifacts-test"
        with self.assertRaisesRegex(RuntimeError, "invalid S3 bucket name"):
            access_deploy.proxy_parameters(self.config, "123456789012", "agent-gateway-test")

    def test_rejects_cross_account_or_wrong_parent_configuration(self):
        self.config["account"] = "999999999999"
        with self.assertRaisesRegex(RuntimeError, "account does not match"):
            access_deploy.proxy_parameters(self.config, "123456789012", "agent-gateway-test")
        self.config["account"] = "123456789012"
        self.config["stack"] = "agent-gateway-other"
        with self.assertRaisesRegex(RuntimeError, "stack does not match"):
            access_deploy.proxy_parameters(self.config, "123456789012", "agent-gateway-test")

    def test_missing_parent_uses_nonfunctional_defaults(self):
        with patch.object(access_deploy, "aws", side_effect=RuntimeError("Stack with id agent-gateway-test does not exist")):
            self.assertEqual(
                access_deploy.parent_proxy_parameters("app", "eu-west-3", "agent-gateway-test", "123456789012"),
                (
                    access_deploy.PLACEHOLDER_BUCKET,
                    access_deploy.PLACEHOLDER_API_ID,
                    "activation/gateway.token",
                ),
            )

    def test_parent_permissions_errors_are_not_silently_ignored(self):
        with patch.object(access_deploy, "aws", side_effect=RuntimeError("AccessDenied")):
            with self.assertRaisesRegex(RuntimeError, "AccessDenied"):
                access_deploy.parent_proxy_parameters("app", "eu-west-3", "agent-gateway-test", "123456789012")

    def test_reads_and_validates_exact_public_proxy_ami(self):
        with patch.object(access_deploy, "aws", return_value={"Parameter": {"Value": "ami-0123456789abcdef0"}}) as aws:
            self.assertEqual(access_deploy.proxy_ami_id("admin", "eu-west-3"), "ami-0123456789abcdef0")
        aws.assert_called_once_with(
            "admin", "eu-west-3", "ssm", "get-parameter",
            "--name", "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64",
        )

    def test_rejects_invalid_proxy_ami_parameter_value(self):
        with patch.object(access_deploy, "aws", return_value={"Parameter": {"Value": "not-an-ami"}}):
            with self.assertRaisesRegex(RuntimeError, "invalid image ID"):
                access_deploy.proxy_ami_id("admin", "eu-west-3")

    def test_deploy_passes_exact_values_to_cloudformation(self):
        with patch.object(access_deploy, "aws", return_value={"Account": "123456789012"}), \
             patch.object(access_deploy, "proxy_ami_id", return_value="ami-0123456789abcdef0"), \
             patch.object(access_deploy, "parent_proxy_parameters", return_value=(
                 "agent-gateway-artifacts-test-a1b2c3", "abc123", "activation/gateway.token"
             )), \
             patch.object(access_deploy.subprocess, "run") as run:
            access_deploy.deploy(
                "admin", "app", "eu-west-3", "123456789012",
                "agent-gateway-access-test", "agent-gateway-test",
                "agent-gateway-artifacts-test", "AgentGatewayTest", "",
            )
        command = run.call_args.args[0]
        self.assertIn("ProxyActivationBucket=agent-gateway-artifacts-test-a1b2c3", command)
        self.assertIn("ProxyAuthzApiId=abc123", command)
        self.assertIn("ProxyGatewayLicenceObject=activation/gateway.token", command)
        self.assertIn("ProxyAmiId=ami-0123456789abcdef0", command)
        self.assertIn("--s3-bucket", command)
        self.assertEqual(command[command.index("--s3-bucket") + 1], "agent-gateway-artifacts-test-a1b2c3")
        self.assertTrue(run.call_args.kwargs["check"])

    def test_deploy_requires_real_staging_bucket_before_parent_exists(self):
        with patch.object(access_deploy, "aws", return_value={"Account": "123456789012"}), \
             patch.object(access_deploy, "proxy_ami_id", return_value="ami-0123456789abcdef0"), \
             patch.object(access_deploy, "parent_proxy_parameters", return_value=(
                 access_deploy.PLACEHOLDER_BUCKET, access_deploy.PLACEHOLDER_API_ID, "activation/gateway.token"
             )), \
             patch.object(access_deploy.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "AWS_ACCESS_S3_BUCKET"):
                access_deploy.deploy(
                    "admin", "app", "eu-west-3", "123456789012",
                    "agent-gateway-access-test", "agent-gateway-test",
                    "agent-gateway-artifacts-test", "AgentGatewayTest", "",
                )
            run.assert_not_called()

    def test_explicit_staging_bucket_is_used_before_parent_exists(self):
        with patch.object(access_deploy, "aws", return_value={"Account": "123456789012"}), \
             patch.object(access_deploy, "proxy_ami_id", return_value="ami-0123456789abcdef0"), \
             patch.object(access_deploy, "parent_proxy_parameters", return_value=(
                 access_deploy.PLACEHOLDER_BUCKET, access_deploy.PLACEHOLDER_API_ID, "activation/gateway.token"
             )), \
             patch.object(access_deploy.subprocess, "run") as run:
            access_deploy.deploy(
                "admin", "app", "eu-west-3", "123456789012",
                "agent-gateway-access-test", "agent-gateway-test",
                "agent-gateway-artifacts-test", "AgentGatewayTest", "template-staging-bucket",
            )
        command = run.call_args.args[0]
        self.assertEqual(command[command.index("--s3-bucket") + 1], "template-staging-bucket")


if __name__ == "__main__":
    unittest.main()

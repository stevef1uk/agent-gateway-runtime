import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts import deploy_azure


def valid_config():
    digest = "a" * 64
    return {
        "subscription_id": "00000000-0000-0000-0000-000000000001",
        "tenant_id": "00000000-0000-0000-0000-000000000002",
        "location": "uksouth",
        "resource_group": "rg-agent-gateway-dev",
        "name_prefix": "agw-dev",
        "key_vault_name": "agent-gateway-dev-kv",
        "key_vault_resource_group": "rg-agent-gateway-secrets",
        "postgres_namespace": "agent-gateway-dev",
        "oidc_issuer_url": "https://login.microsoftonline.com/tenant/v2.0",
        "oidc_client_id": "00000000-0000-0000-0000-000000000003",
        "web_admin_emails": "admin@example.com",
        "emotion_image": f"registry.example.com/agent/emotion@sha256:{digest}",
        "private_registry": {
            "server": "",
            "username": "",
            "password_secret_name": "registry-password",
        },
        "images": {
            name: f"registry.example.com/agent/{name}@sha256:{digest}"
            for name in deploy_azure.IMAGE_KEYS
        },
    }


class ValidateConfigTests(unittest.TestCase):
    def test_accepts_digest_pinned_config(self):
        self.assertEqual(deploy_azure.validate_config(valid_config()), [])

    def test_rejects_mutable_image_tag(self):
        config = valid_config()
        config["images"]["web"] = "registry.example.com/agent/web:latest"

        errors = deploy_azure.validate_config(config)

        self.assertTrue(any("images.web" in error for error in errors))

    def test_rejects_image_host_mismatch_for_private_registry(self):
        config = valid_config()
        config["private_registry"] = {
            "server": "registry.example.com",
            "username": "release-puller",
            "password_secret_name": "registry-password",
        }
        config["images"]["tokensvc"] = (
            "other.example.com/agent/tokensvc@sha256:" + "b" * 64
        )

        errors = deploy_azure.validate_config(config)

        self.assertTrue(any("image hosts must match" in error for error in errors))

    def test_private_service_registry_does_not_constrain_emotion_image_host(self):
        config = valid_config()
        config["private_registry"] = {
            "server": "registry.example.com",
            "username": "release-puller",
            "password_secret_name": "registry-password",
        }
        config["emotion_image"] = (
            "public.example.com/agent/emotion@sha256:" + "b" * 64
        )

        self.assertEqual(deploy_azure.validate_config(config), [])

    def test_validate_action_allows_example_image_placeholders(self):
        config = valid_config()
        config["images"] = {name: "" for name in deploy_azure.IMAGE_KEYS}
        config["emotion_image"] = ""

        self.assertEqual(deploy_azure.validate_config(config, require_images=False), [])

    def test_bundled_azure_example_has_pinned_release_images(self):
        config_path = (
            Path(deploy_azure.__file__).resolve().parents[1]
            / "deploy"
            / "azure"
            / "azure-config.example.json"
        )
        config = json.loads(config_path.read_text(encoding="utf-8"))

        errors = deploy_azure.validate_config(config)

        self.assertFalse(
            [
                error
                for error in errors
                if "images." in error or "emotion_image" in error
            ],
            errors,
        )

    def test_rejects_resource_group_collisions_with_key_vault_or_emotion(self):
        config = valid_config()
        config["key_vault_resource_group"] = config["resource_group"]

        errors = deploy_azure.validate_config(config)

        self.assertTrue(any("resource groups must be different" in error for error in errors))

    def test_rejects_invalid_key_vault_name(self):
        config = valid_config()
        config["key_vault_name"] = "vault' | [?name"

        errors = deploy_azure.validate_config(config)

        self.assertTrue(any("key_vault_name" in error for error in errors))

    def test_rejects_private_registry_secret_name_collision(self):
        config = valid_config()
        config["private_registry"] = {
            "server": "registry.example.com",
            "username": "release-puller",
            "password_secret_name": "database-url",
        }

        errors = deploy_azure.validate_config(config)

        self.assertTrue(any("must not collide" in error for error in errors))


class RoleAssignmentTests(unittest.TestCase):
    def test_role_assignment_cleanup_filters_out_inherited_and_unrelated_roles(self):
        scope = "/subscriptions/sub/resourceGroups/rg/keyVaults/vault"
        with mock.patch.object(
            deploy_azure,
            "run_json",
            return_value=[
                {
                    "principalId": "principal",
                    "roleDefinitionName": "Key Vault Secrets User",
                    "scope": scope,
                    "name": "owned-assignment",
                },
                {
                    "principalId": "principal",
                    "roleDefinitionName": "Key Vault Secrets User",
                    "scope": "/subscriptions/sub",
                    "name": "inherited-assignment",
                },
                {
                    "principalId": "principal",
                    "roleDefinitionName": "Reader",
                    "scope": scope,
                    "name": "reader-assignment",
                },
            ],
        ):
            matches = deploy_azure.role_assignments(
                "principal", scope, deploy_azure.KEY_VAULT_SECRETS_USER
            )

        self.assertEqual([item["name"] for item in matches], ["owned-assignment"])

    def test_assignment_id_is_stable(self):
        expected = deploy_azure.assignment_id(
            "principal", "/subscriptions/sub/resourceGroups/rg", "Reader"
        )
        self.assertEqual(
            expected,
            deploy_azure.assignment_id(
                "PRINCIPAL", "/SUBSCRIPTIONS/SUB/RESOURCEGROUPS/RG", "Reader"
            ),
        )

    def test_group_ownership_is_bound_to_deployment_prefix(self):
        with (
            mock.patch.object(deploy_azure, "run", return_value="true"),
            mock.patch.object(
                deploy_azure,
                "run_json",
                return_value={
                    "tags": {
                        "managedBy": deploy_azure.MANAGED_BY,
                        "deployment": "other-deployment",
                    }
                },
            ),
        ):
            with self.assertRaises(deploy_azure.AzureError):
                deploy_azure.require_owned_group(
                    "rg-example",
                    deployment="agw-dev",
                    must_exist=True,
                )


class SecretFileTests(unittest.TestCase):
    def test_secret_file_must_be_private_and_owned(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "secret"
            path.write_bytes(b"secret-value")
            path.chmod(0o600)
            self.assertEqual(deploy_azure.secure_file_bytes(path), b"secret-value")

            path.chmod(0o644)
            with self.assertRaises(deploy_azure.AzureError):
                deploy_azure.secure_file_bytes(path)

    def test_rejects_symlink_secret_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "secret"
            target = Path(directory) / "target"
            target.write_bytes(b"secret-value")
            target.chmod(0o600)
            path.symlink_to(target)

            with self.assertRaises(deploy_azure.AzureError):
                deploy_azure.secure_file_bytes(path)

    def test_private_licence_override_still_requires_private_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "licence"
            path.write_bytes(b"private-licence")
            path.chmod(0o644)

            with self.assertRaises(deploy_azure.AzureError):
                deploy_azure.licence_file_bytes(path)

    def test_neon_database_url_is_extracted_without_printing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "neon.json"
            path.write_text(
                json.dumps({"database_url": "postgresql://user:pass@host/db?sslmode=require"}),
                encoding="utf-8",
            )
            path.chmod(0o600)

            self.assertEqual(
                deploy_azure.neon_database_url(path),
                b"postgresql://user:pass@host/db?sslmode=require",
            )

    def test_neon_database_url_requires_tls(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "neon.json"
            path.write_text(
                json.dumps({"database_url": "postgresql://user:pass@host/db?sslmode=disable"}),
                encoding="utf-8",
            )
            path.chmod(0o600)

            with self.assertRaises(deploy_azure.AzureError):
                deploy_azure.neon_database_url(path)

    def test_secret_list_tracks_enabled_state(self):
        with mock.patch.object(
            deploy_azure,
            "run_json",
            return_value=[
                {"name": "database-url", "enabled": True},
                {"name": "jwt-secret", "enabled": False},
            ],
        ):
            states = deploy_azure.secret_states_in_vault(valid_config())

        self.assertEqual(states, {"database-url": True, "jwt-secret": False})

    def test_secret_upload_uses_private_file_and_deployment_tags(self):
        config = valid_config()
        observed = {}

        def fake_run(args, **kwargs):
            path = Path(args[args.index("--file") + 1])
            observed["value"] = path.read_bytes()
            observed["mode"] = path.stat().st_mode & 0o777
            observed["args"] = args
            observed["capture"] = kwargs.get("capture")
            return ""

        with mock.patch.object(deploy_azure, "run", side_effect=fake_run):
            deploy_azure.upload_secret(config, "licence-token", b"licence-value")

        self.assertEqual(observed["value"], b"licence-value")
        self.assertEqual(observed["mode"], 0o600)
        self.assertIn("managedBy=agent-gateway-runtime-azure", observed["args"])
        self.assertIn("deployment=agw-dev", observed["args"])
        self.assertNotIn("licence-value", observed["args"])
        self.assertFalse(observed["capture"])

    def test_bundled_public_evaluation_licence_is_available_by_default(self):
        token = deploy_azure.licence_file_bytes(deploy_azure.DEFAULT_LICENCE_TOKEN)

        self.assertTrue(token)

    def test_upload_secrets_defaults_to_bundled_licence(self):
        argv = [
            "deploy_azure.py",
            "upload-secrets",
            "--oidc-client-secret-file",
            "/tmp/oidc-client-secret",
        ]
        with (
            mock.patch.object(deploy_azure.sys, "argv", argv),
            mock.patch.object(deploy_azure, "load_config", return_value=valid_config()),
            mock.patch.object(deploy_azure, "ensure_azure_tools"),
            mock.patch.object(deploy_azure, "account"),
            mock.patch.object(deploy_azure, "get_vault", return_value={"id": "vault-id"}),
            mock.patch.object(deploy_azure, "upload_secrets") as upload,
        ):
            self.assertEqual(deploy_azure.main(), 0)

        self.assertEqual(
            upload.call_args.kwargs["licence_file"],
            deploy_azure.DEFAULT_LICENCE_TOKEN,
        )


if __name__ == "__main__":
    unittest.main()

from contextlib import redirect_stdout
from io import BytesIO
from io import StringIO
import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from urllib.error import HTTPError
from unittest.mock import patch

from scripts.neon_setup import (
    API_BASE_URL,
    ConfigError,
    NeonApiError,
    NeonClient,
    destroy_created_project,
    load_config,
    main,
    project_summary,
    setup_project,
)


VALID_CONFIG = {
    "provider": "neon",
    "mode": "existing",
    "project_id": "example-project-123",
    "project_name": "",
    "region_id": "aws-eu-west-2",
    "branch_id": "",
    "database_name": "agent_gateway_dev",
    "application_role": "agent_gateway_app",
}
CREATE_CONFIG = {
    **VALID_CONFIG,
    "mode": "create",
    "project_id": "",
    "project_name": "Agent Gateway Development",
}


class FakeNeonClient:
    def __init__(self) -> None:
        self.created_projects: list[tuple[str, str, str, str]] = []
        self.created_roles: list[str] = []
        self.created_databases: list[tuple[str, str]] = []
        self.deleted_projects: list[str] = []
        self.project_id = "created-project"
        self.project = {
            "id": self.project_id,
            "name": CREATE_CONFIG["project_name"],
            "region_id": VALID_CONFIG["region_id"],
        }
        self.roles = [{"name": VALID_CONFIG["application_role"]}]
        self.databases = [
            {
                "name": VALID_CONFIG["database_name"],
                "owner_name": VALID_CONFIG["application_role"],
            }
        ]

    def get_project(self, project_id: str) -> dict[str, object]:
        if project_id not in {self.project_id, VALID_CONFIG["project_id"]}:
            raise NeonApiError("Not found.", 404)
        project = dict(self.project)
        project["id"] = project_id
        return {"project": project}

    def create_project(
        self, name: str, region: str, database: str, role: str
    ) -> dict[str, object]:
        self.created_projects.append((name, region, database, role))
        return {
            "project": self.project,
            "branch": {"id": "br-main"},
            "operations": [{"id": "project-operation", "status": "finished"}],
        }

    def list_branches(self, project_id: str) -> list[dict[str, object]]:
        return [{"id": "br-main", "default": True}]

    def list_roles(
        self, project_id: str, branch_id: str
    ) -> list[dict[str, object]]:
        return list(self.roles)

    def create_role(
        self, project_id: str, branch_id: str, name: str
    ) -> dict[str, object]:
        self.created_roles.append(name)
        self.roles.append({"name": name})
        return {"role": {"name": name}, "operations": []}

    def list_databases(
        self, project_id: str, branch_id: str
    ) -> list[dict[str, object]]:
        return list(self.databases)

    def create_database(
        self,
        project_id: str,
        branch_id: str,
        name: str,
        owner_name: str,
    ) -> dict[str, object]:
        self.created_databases.append((name, owner_name))
        self.databases.append({"name": name, "owner_name": owner_name})
        return {"database": {"name": name}, "operations": []}

    def list_endpoints(
        self, project_id: str, branch_id: str
    ) -> list[dict[str, object]]:
        return [{"id": "ep-main", "type": "read_write", "disabled": False}]

    def connection_uri(
        self,
        project_id: str,
        branch_id: str,
        endpoint_id: str,
        database_name: str,
        role_name: str,
    ) -> str:
        return "postgresql://app:private-password@ep.example/db?sslmode=require"

    def wait_for_operations(
        self, project_id: str, operations: list[dict[str, object]]
    ) -> None:
        return None

    def delete_project(self, project_id: str) -> None:
        self.deleted_projects.append(project_id)


class NeonConfigTests(unittest.TestCase):
    def write_config(self, value: object) -> Path:
        temporary = tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", delete=False
        )
        self.addCleanup(Path(temporary.name).unlink, missing_ok=True)
        with temporary:
            json.dump(value, temporary)
        return Path(temporary.name)

    def test_loads_valid_non_secret_config(self) -> None:
        self.assertEqual(load_config(self.write_config(VALID_CONFIG)), VALID_CONFIG)

    def test_accepts_new_project_config_without_project_id(self) -> None:
        self.assertEqual(
            load_config(self.write_config(CREATE_CONFIG)), CREATE_CONFIG
        )

    def test_rejects_secret_or_unknown_fields(self) -> None:
        config = {**VALID_CONFIG, "database_url": "postgres://private"}
        with self.assertRaisesRegex(ConfigError, "Unsupported config field"):
            load_config(self.write_config(config))

    def test_rejects_invalid_database_identifier(self) -> None:
        config = {**VALID_CONFIG, "database_name": "Agent-Gateway"}
        with self.assertRaisesRegex(ConfigError, "database_name"):
            load_config(self.write_config(config))

    def test_rejects_missing_fields(self) -> None:
        config = {key: value for key, value in VALID_CONFIG.items() if key != "region_id"}
        with self.assertRaisesRegex(ConfigError, "Missing required config"):
            load_config(self.write_config(config))

    def test_rejects_project_id_in_create_mode(self) -> None:
        config = {**CREATE_CONFIG, "project_id": "some-existing-project"}
        with self.assertRaisesRegex(ConfigError, "project_id must be empty"):
            load_config(self.write_config(config))


class NeonApiTests(unittest.TestCase):
    def test_client_sends_bearer_auth_and_parses_project(self) -> None:
        response = BytesIO(
            json.dumps(
                {
                    "project": {
                        "id": VALID_CONFIG["project_id"],
                        "name": "Development",
                        "region_id": VALID_CONFIG["region_id"],
                    }
                }
            ).encode()
        )
        with patch("scripts.neon_setup.urlopen", return_value=response) as urlopen_mock:
            project = NeonClient("test-key").get_project(VALID_CONFIG["project_id"])

        request = urlopen_mock.call_args.args[0]
        self.assertEqual(
            request.full_url,
            f"{API_BASE_URL}/projects/{VALID_CONFIG['project_id']}",
        )
        self.assertEqual(request.get_header("Authorization"), "Bearer test-key")
        self.assertEqual(project["project"]["name"], "Development")

    def test_create_project_uses_configured_region_database_and_role(self) -> None:
        response = BytesIO(b'{"project":{"id":"created-project"}}')
        with patch("scripts.neon_setup.urlopen", return_value=response) as urlopen_mock:
            NeonClient("test-key").create_project(
                CREATE_CONFIG["project_name"],
                CREATE_CONFIG["region_id"],
                CREATE_CONFIG["database_name"],
                CREATE_CONFIG["application_role"],
            )

        request = urlopen_mock.call_args.args[0]
        self.assertEqual(request.full_url, f"{API_BASE_URL}/projects")
        self.assertEqual(request.method, "POST")
        self.assertEqual(
            json.loads(request.data),
            {
                "project": {
                    "name": CREATE_CONFIG["project_name"],
                    "region_id": CREATE_CONFIG["region_id"],
                    "branch": {
                        "name": "main",
                        "database_name": CREATE_CONFIG["database_name"],
                        "role_name": CREATE_CONFIG["application_role"],
                    },
                }
            },
        )

    def test_connection_uri_parameters_are_encoded(self) -> None:
        response = BytesIO(b'{"uri":"postgresql://app:private@host/db"}')
        with patch("scripts.neon_setup.urlopen", return_value=response) as urlopen_mock:
            uri = NeonClient("test-key").connection_uri(
                "example-project",
                "br-main",
                "ep-main",
                "agent_gateway_dev",
                "agent_gateway_app",
            )
        request = urlopen_mock.call_args.args[0]
        self.assertIn(
            "/projects/example-project/connection_uri?",
            request.full_url,
        )
        self.assertIn("database_name=agent_gateway_dev", request.full_url)
        self.assertEqual(
            uri, "postgresql://app:private@host/db?sslmode=require"
        )

    def test_connection_uri_rejects_disabled_tls(self) -> None:
        response = BytesIO(
            b'{"uri":"postgresql://app:private@host/db?sslmode=disable"}'
        )
        with patch("scripts.neon_setup.urlopen", return_value=response):
            with self.assertRaisesRegex(NeonApiError, "TLS disabled"):
                NeonClient("test-key").connection_uri(
                    "example-project",
                    "br-main",
                    "ep-main",
                    "agent_gateway_dev",
                    "agent_gateway_app",
                )

    def test_api_error_does_not_expose_response_body(self) -> None:
        response = BytesIO(b'{"password":"sensitive-response-value"}')
        api_error = HTTPError(
            f"{API_BASE_URL}/projects/{VALID_CONFIG['project_id']}",
            403,
            "Forbidden",
            {},
            response,
        )
        with patch("scripts.neon_setup.urlopen", side_effect=api_error):
            with self.assertRaises(NeonApiError) as raised:
                NeonClient("test-key").get_project(VALID_CONFIG["project_id"])
        self.assertEqual(raised.exception.status_code, 403)
        self.assertNotIn("sensitive-response-value", str(raised.exception))

    def test_project_summary_exposes_only_non_secret_metadata(self) -> None:
        client = FakeNeonClient()
        summary = project_summary(VALID_CONFIG, client, VALID_CONFIG["project_id"])
        self.assertEqual(
            summary,
            {
                "project_id": VALID_CONFIG["project_id"],
                "name": CREATE_CONFIG["project_name"],
                "region_id": VALID_CONFIG["region_id"],
                "database_name": VALID_CONFIG["database_name"],
                "application_role": VALID_CONFIG["application_role"],
            },
        )
        self.assertNotIn("password", summary)

    def test_rejects_region_mismatch_before_setup(self) -> None:
        client = FakeNeonClient()
        client.project["region_id"] = "aws-us-east-2"
        with self.assertRaisesRegex(NeonApiError, "region"):
            project_summary(VALID_CONFIG, client, VALID_CONFIG["project_id"])


class NeonProvisioningTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state_path = self.root / "state.json"
        self.credentials_path = self.root / "credentials.json"

    def test_new_project_requires_exact_confirmation(self) -> None:
        client = FakeNeonClient()
        with self.assertRaisesRegex(ConfigError, "--confirm-create"):
            setup_project(
                CREATE_CONFIG,
                client,
                self.state_path,
                self.credentials_path,
                confirm_create=None,
                confirm_existing_project=None,
            )
        self.assertEqual(client.created_projects, [])

    def test_creates_project_and_writes_private_credentials(self) -> None:
        client = FakeNeonClient()
        summary = setup_project(
            CREATE_CONFIG,
            client,
            self.state_path,
            self.credentials_path,
            confirm_create=CREATE_CONFIG["project_name"],
            confirm_existing_project=None,
        )
        self.assertEqual(summary["project_id"], client.project_id)
        self.assertEqual(summary["branch_id"], "br-main")
        self.assertEqual(len(client.created_projects), 1)
        self.assertEqual(
            stat.S_IMODE(self.state_path.stat().st_mode),
            stat.S_IRUSR | stat.S_IWUSR,
        )
        self.assertEqual(
            stat.S_IMODE(self.credentials_path.stat().st_mode),
            stat.S_IRUSR | stat.S_IWUSR,
        )
        credential_file = json.loads(self.credentials_path.read_text())
        self.assertIn("private-password", credential_file["database_url"])

    def test_setup_rerun_does_not_create_project_again(self) -> None:
        client = FakeNeonClient()
        for _ in range(2):
            setup_project(
                CREATE_CONFIG,
                client,
                self.state_path,
                self.credentials_path,
                confirm_create=CREATE_CONFIG["project_name"],
                confirm_existing_project=None,
            )
        self.assertEqual(len(client.created_projects), 1)

    def test_failed_setup_keeps_state_for_safe_teardown(self) -> None:
        class FailingNeonClient(FakeNeonClient):
            def wait_for_operations(
                self, project_id: str, operations: list[dict[str, object]]
            ) -> None:
                raise NeonApiError("Provisioning failed.")

        with self.assertRaisesRegex(NeonApiError, "Provisioning failed"):
            setup_project(
                CREATE_CONFIG,
                FailingNeonClient(),
                self.state_path,
                self.credentials_path,
                confirm_create=CREATE_CONFIG["project_name"],
                confirm_existing_project=None,
            )
        state = json.loads(self.state_path.read_text())
        self.assertEqual(state["project_id"], "created-project")
        self.assertEqual(
            state["credentials_file"], str(self.credentials_path.resolve())
        )

    def test_setup_command_never_prints_connection_url(self) -> None:
        config_path = self.root / "neon.json"
        config_path.write_text(json.dumps(CREATE_CONFIG))
        client = FakeNeonClient()
        output = StringIO()
        with (
            patch.dict(os.environ, {"NEON_API_KEY": "test-key"}),
            patch("scripts.neon_setup.NeonClient", return_value=client),
            redirect_stdout(output),
        ):
            result = main(
                [
                    "--config",
                    str(config_path),
                    "--state-file",
                    str(self.state_path),
                    "--credentials-file",
                    str(self.credentials_path),
                    "setup",
                    "--confirm-create",
                    CREATE_CONFIG["project_name"],
                ]
            )
        self.assertEqual(result, 0)
        self.assertNotIn("private-password", output.getvalue())
        self.assertNotIn("postgresql://", output.getvalue())

    def test_existing_project_requires_exact_confirmation(self) -> None:
        client = FakeNeonClient()
        with self.assertRaisesRegex(ConfigError, "--confirm-existing-project"):
            setup_project(
                VALID_CONFIG,
                client,
                self.state_path,
                self.credentials_path,
                confirm_create=None,
                confirm_existing_project="wrong-project",
            )
        self.assertEqual(client.created_roles, [])
        self.assertEqual(client.created_databases, [])

    def test_existing_project_setup_selects_or_creates_role_and_database(self) -> None:
        client = FakeNeonClient()
        client.roles = []
        client.databases = []
        summary = setup_project(
            VALID_CONFIG,
            client,
            self.state_path,
            self.credentials_path,
            confirm_create=None,
            confirm_existing_project=VALID_CONFIG["project_id"],
        )
        self.assertEqual(summary["branch_id"], "br-main")
        self.assertEqual(client.created_roles, [VALID_CONFIG["application_role"]])
        self.assertEqual(
            client.created_databases,
            [(VALID_CONFIG["database_name"], VALID_CONFIG["application_role"])],
        )
        self.assertFalse(self.state_path.exists())

    def test_database_with_unexpected_owner_is_not_rewritten(self) -> None:
        client = FakeNeonClient()
        client.databases[0]["owner_name"] = "some_other_role"
        with self.assertRaisesRegex(ConfigError, "different owner"):
            setup_project(
                VALID_CONFIG,
                client,
                self.state_path,
                self.credentials_path,
                confirm_create=None,
                confirm_existing_project=VALID_CONFIG["project_id"],
            )
        self.assertEqual(client.created_databases, [])


class NeonTeardownTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state_path = self.root / "state.json"
        self.credentials_path = self.root / "credentials.json"
        self.state_path.write_text(
            json.dumps(
                {
                    "owner": "agent-gateway-runtime-neon-setup",
                    "project_id": "created-project",
                    "project_name": "Agent Gateway Development",
                    "region_id": VALID_CONFIG["region_id"],
                }
            )
        )
        self.credentials_path.write_text('{"database_url":"postgres://private"}')

    def test_destroy_requires_exact_project_confirmation(self) -> None:
        client = FakeNeonClient()
        with self.assertRaisesRegex(ConfigError, "--confirm-project-id"):
            destroy_created_project(
                CREATE_CONFIG,
                client,
                self.state_path,
                self.credentials_path,
                "wrong-project",
            )
        self.assertEqual(client.deleted_projects, [])
        self.assertTrue(self.state_path.exists())
        self.assertTrue(self.credentials_path.exists())

    def test_destroy_deletes_only_recorded_project_and_local_credentials(self) -> None:
        client = FakeNeonClient()
        project_id = destroy_created_project(
            CREATE_CONFIG,
            client,
            self.state_path,
            self.credentials_path,
            "created-project",
        )
        self.assertEqual(project_id, "created-project")
        self.assertEqual(client.deleted_projects, ["created-project"])
        self.assertFalse(self.state_path.exists())
        self.assertFalse(self.credentials_path.exists())

    def test_existing_project_without_ownership_state_is_never_deleted(self) -> None:
        client = FakeNeonClient()
        self.state_path.unlink()
        with self.assertRaisesRegex(ConfigError, "existing projects are never deleted"):
            destroy_created_project(
                VALID_CONFIG,
                client,
                self.state_path,
                self.credentials_path,
                VALID_CONFIG["project_id"],
            )
        self.assertEqual(client.deleted_projects, [])
        self.assertTrue(self.credentials_path.exists())

    def test_destroy_cleans_local_files_when_project_is_already_gone(self) -> None:
        class MissingProjectClient(FakeNeonClient):
            def delete_project(self, project_id: str) -> None:
                raise NeonApiError("Not found.", 404)

        destroy_created_project(
            CREATE_CONFIG,
            MissingProjectClient(),
            self.state_path,
            self.credentials_path,
            "created-project",
        )
        self.assertFalse(self.state_path.exists())
        self.assertFalse(self.credentials_path.exists())


if __name__ == "__main__":
    unittest.main()

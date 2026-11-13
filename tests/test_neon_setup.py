from io import BytesIO
import json
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
    load_config,
    project_summary,
)


VALID_CONFIG = {
    "provider": "neon",
    "mode": "existing",
    "project_id": "example-project-123",
    "region_id": "aws-eu-west-2",
    "database_name": "agent_gateway_dev",
    "application_role": "agent_gateway_app",
}


class NeonConfigTests(unittest.TestCase):
    def write_config(self, value: object) -> Path:
        temporary = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", delete=False)
        self.addCleanup(Path(temporary.name).unlink, missing_ok=True)
        with temporary:
            json.dump(value, temporary)
        return Path(temporary.name)

    def test_loads_valid_non_secret_config(self) -> None:
        self.assertEqual(load_config(self.write_config(VALID_CONFIG)), VALID_CONFIG)

    def test_rejects_secret_or_unknown_fields(self) -> None:
        config = {**VALID_CONFIG, "database_url": "postgres://user:password@example"}
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


class NeonStatusTests(unittest.TestCase):
    def test_client_fetches_project_with_bearer_auth(self) -> None:
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
        self.assertEqual(project["name"], "Development")

    def test_project_summary_exposes_only_non_secret_metadata(self) -> None:
        project = {
            "id": VALID_CONFIG["project_id"],
            "name": "Development",
            "region_id": VALID_CONFIG["region_id"],
            "connection_uri": "postgres://private",
            "password": "do-not-print",
        }
        with patch.object(NeonClient, "get_project", return_value=project):
            summary = project_summary(VALID_CONFIG, NeonClient("test-key"))

        self.assertEqual(
            summary,
            {
                "project_id": VALID_CONFIG["project_id"],
                "name": "Development",
                "region_id": VALID_CONFIG["region_id"],
                "database_name": VALID_CONFIG["database_name"],
                "application_role": VALID_CONFIG["application_role"],
            },
        )
        self.assertNotIn("password", summary)
        self.assertNotIn("connection_uri", summary)

    def test_api_error_does_not_expose_response_body(self) -> None:
        response = BytesIO(b'{"password":"sensitive-response-value"}')
        api_error = HTTPError(
            f"{API_BASE_URL}/projects/{VALID_CONFIG['project_id']}",
            401,
            "Unauthorized",
            {},
            response,
        )
        with patch("scripts.neon_setup.urlopen", side_effect=api_error):
            with self.assertRaises(NeonApiError) as raised:
                NeonClient("test-key").get_project(VALID_CONFIG["project_id"])

        self.assertNotIn("sensitive-response-value", str(raised.exception))

    def test_rejects_region_mismatch(self) -> None:
        project = {
            "id": VALID_CONFIG["project_id"],
            "name": "Development",
            "region_id": "aws-us-east-2",
        }
        with patch.object(NeonClient, "get_project", return_value=project):
            with self.assertRaisesRegex(NeonApiError, "region"):
                project_summary(VALID_CONFIG, NeonClient("test-key"))

if __name__ == "__main__":
    unittest.main()

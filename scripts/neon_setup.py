#!/usr/bin/env python3
"""Validate non-secret Neon configuration and inspect an existing project."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

API_BASE_URL = "https://console.neon.tech/api/v2"
CONFIG_KEYS = {
    "provider",
    "mode",
    "project_id",
    "region_id",
    "database_name",
    "application_role",
}
IDENTIFIER_PATTERN = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")
PROJECT_ID_PATTERN = re.compile(r"^[a-zA-Z0-9-]{1,128}$")
REGION_ID_PATTERN = re.compile(r"^aws-[a-z]+-[a-z]+-\d+$")


class ConfigError(ValueError):
    """Raised when a Neon config is missing, malformed, or unsafe."""


class NeonApiError(RuntimeError):
    """Raised when Neon returns an invalid or unsuccessful API response."""


def load_config(path: Path) -> dict[str, str]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ConfigError(f"Cannot read config file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigError(f"Config file is not valid JSON: {path}") from exc

    if not isinstance(raw, dict):
        raise ConfigError("Config root must be a JSON object.")

    unknown_keys = set(raw) - CONFIG_KEYS
    if unknown_keys:
        names = ", ".join(sorted(unknown_keys))
        raise ConfigError(f"Unsupported config field(s): {names}")

    required = CONFIG_KEYS
    missing = required - set(raw)
    if missing:
        names = ", ".join(sorted(missing))
        raise ConfigError(f"Missing required config field(s): {names}")

    if not all(isinstance(value, str) for value in raw.values()):
        raise ConfigError("All config values must be strings.")
    if raw["provider"] != "neon":
        raise ConfigError("provider must be 'neon'.")
    if raw["mode"] not in {"existing", "create"}:
        raise ConfigError("mode must be 'existing' or 'create'.")
    if not PROJECT_ID_PATTERN.fullmatch(raw["project_id"]):
        raise ConfigError("project_id must contain only letters, digits, or hyphens.")
    if not REGION_ID_PATTERN.fullmatch(raw["region_id"]):
        raise ConfigError("region_id must be a valid Neon AWS region identifier.")
    for field in ("database_name", "application_role"):
        if not IDENTIFIER_PATTERN.fullmatch(raw[field]):
            raise ConfigError(
                f"{field} must be a lowercase PostgreSQL identifier "
                "of at most 63 characters."
            )

    return raw


class NeonClient:
    def __init__(self, api_key: str, timeout: float = 15.0) -> None:
        if not api_key.strip():
            raise ValueError("Neon API key cannot be empty.")
        self._api_key = api_key
        self._timeout = timeout

    def get_project(self, project_id: str) -> dict[str, Any]:
        request = Request(
            f"{API_BASE_URL}/projects/{project_id}",
            headers={
                "Accept": "application/json",
                "Authorization": "Bearer " + self._api_key,
            },
        )
        try:
            with urlopen(request, timeout=self._timeout) as response:
                payload = json.load(response)
        except HTTPError as exc:
            raise NeonApiError(
                f"Neon API request failed with HTTP {exc.code}."
            ) from None
        except URLError as exc:
            raise NeonApiError(
                f"Could not reach the Neon API: {exc.reason}."
            ) from None
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise NeonApiError("Neon API returned invalid JSON.") from exc

        if not isinstance(payload, dict) or not isinstance(payload.get("project"), dict):
            raise NeonApiError("Neon API response did not contain a project.")
        project = payload["project"]
        if project.get("id") != project_id:
            raise NeonApiError("Neon API returned a different project than requested.")
        return project


def project_summary(config: dict[str, str], client: NeonClient) -> dict[str, str]:
    project = client.get_project(config["project_id"])
    region_id = project.get("region_id")
    if region_id != config["region_id"]:
        raise NeonApiError(
            "Configured region does not match the Neon project's region."
        )
    name = project.get("name")
    if not isinstance(name, str) or not name:
        raise NeonApiError("Neon API response did not contain a project name.")
    return {
        "project_id": project["id"],
        "name": name,
        "region_id": region_id,
        "database_name": config["database_name"],
        "application_role": config["application_role"],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument(
        "command",
        choices=("validate", "status"),
        help="validate non-secret config or inspect an existing Neon project",
    )
    args = parser.parse_args(argv)

    try:
        config = load_config(args.config)
        if args.command == "validate":
            print("Configuration is valid (non-secret fields only).")
            return 0
        if config["mode"] != "existing":
            raise ConfigError("status is currently supported only for existing projects.")
        api_key = os.environ.get("NEON_API_KEY", "")
        if not api_key:
            raise ConfigError("Set NEON_API_KEY in the process environment to run status.")
        summary = project_summary(config, NeonClient(api_key))
        print(json.dumps(summary, indent=2))
        return 0
    except (ConfigError, NeonApiError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

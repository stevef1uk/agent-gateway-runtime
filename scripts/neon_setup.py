#!/usr/bin/env python3
"""Validate, provision, inspect, and safely remove the configured Neon project."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import sys
import tempfile
import time
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qsl, quote, urlencode, urlsplit, urlunsplit
from urllib.request import Request, urlopen

API_BASE_URL = "https://console.neon.tech/api/v2"
CONFIG_KEYS = {
    "provider",
    "mode",
    "project_id",
    "project_name",
    "region_id",
    "branch_id",
    "database_name",
    "application_role",
}
IDENTIFIER_PATTERN = re.compile(r"^[a-z_][a-z0-9_]{0,62}$")
PROJECT_ID_PATTERN = re.compile(r"^[a-z0-9-]{1,60}$")
REGION_ID_PATTERN = re.compile(r"^aws-[a-z]+-[a-z]+-\d+$")
STATE_OWNER = "agent-gateway-runtime-neon-setup"
DEFAULT_STATE_FILE = Path("config/neon-state.json")
DEFAULT_CREDENTIALS_FILE = Path("config/neon-credentials.json")


class ConfigError(ValueError):
    """Raised when a Neon config is missing, malformed, or unsafe."""


class NeonApiError(RuntimeError):
    """Raised when Neon returns an invalid or unsuccessful API response."""

    def __init__(self, message: str, status_code: int | None = None) -> None:
        super().__init__(message)
        self.status_code = status_code


def load_config(path: Path) -> dict[str, str]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise ConfigError("Cannot read the Neon config file.") from exc
    except json.JSONDecodeError as exc:
        raise ConfigError("Neon config file is not valid JSON.") from exc

    if not isinstance(raw, dict):
        raise ConfigError("Config root must be a JSON object.")

    unknown_keys = set(raw) - CONFIG_KEYS
    if unknown_keys:
        names = ", ".join(sorted(unknown_keys))
        raise ConfigError(f"Unsupported config field(s): {names}")

    missing = CONFIG_KEYS - set(raw)
    if missing:
        names = ", ".join(sorted(missing))
        raise ConfigError(f"Missing required config field(s): {names}")

    if not all(isinstance(value, str) for value in raw.values()):
        raise ConfigError("All config values must be strings.")
    if raw["provider"] != "neon":
        raise ConfigError("provider must be 'neon'.")
    if raw["mode"] not in {"existing", "create"}:
        raise ConfigError("mode must be 'existing' or 'create'.")
    if raw["mode"] == "existing":
        if not PROJECT_ID_PATTERN.fullmatch(raw["project_id"]):
            raise ConfigError(
                "project_id must be a Neon project ID when mode is 'existing'."
            )
        if raw["project_name"]:
            raise ConfigError("project_name must be empty when mode is 'existing'.")
    else:
        if raw["project_id"]:
            raise ConfigError("project_id must be empty when mode is 'create'.")
        if not raw["project_name"].strip() or len(raw["project_name"]) > 256:
            raise ConfigError(
                "project_name is required and must be at most 256 characters "
                "when mode is 'create'."
            )
    if not REGION_ID_PATTERN.fullmatch(raw["region_id"]):
        raise ConfigError("region_id must be a valid Neon AWS region identifier.")
    if raw["branch_id"] and not PROJECT_ID_PATTERN.fullmatch(raw["branch_id"]):
        raise ConfigError("branch_id must be a valid Neon branch ID.")
    for field in ("database_name", "application_role"):
        if not IDENTIFIER_PATTERN.fullmatch(raw[field]):
            raise ConfigError(
                f"{field} must be a lowercase PostgreSQL identifier "
                "of at most 63 characters."
            )

    return raw


def _encoded_path(*parts: str) -> str:
    return "/".join(quote(part, safe="") for part in parts)


class NeonClient:
    def __init__(self, api_key: str, timeout: float = 15.0) -> None:
        if not api_key.strip():
            raise ValueError("Neon API key cannot be empty.")
        self._api_key = api_key
        self._timeout = timeout

    def request(
        self,
        method: str,
        path: str,
        *,
        query: dict[str, str] | None = None,
        payload: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        url = f"{API_BASE_URL}{path}"
        if query:
            url += "?" + urlencode(query)
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        headers = {
            "Accept": "application/json",
            "Authorization": f"Bearer {self._api_key}",
        }
        if payload is not None:
            headers["Content-Type"] = "application/json"
        request = Request(url, data=data, headers=headers, method=method)
        try:
            with urlopen(request, timeout=self._timeout) as response:
                body = response.read()
        except HTTPError as exc:
            raise NeonApiError(
                f"Neon API request failed with HTTP {exc.code}.", exc.code
            ) from None
        except URLError as exc:
            raise NeonApiError("Could not reach the Neon API.") from exc

        if not body:
            return {}
        try:
            result = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise NeonApiError("Neon API returned invalid JSON.") from exc
        if not isinstance(result, dict):
            raise NeonApiError("Neon API returned an unexpected response.")
        return result

    def get_project(self, project_id: str) -> dict[str, Any]:
        payload = self.request("GET", f"/projects/{_encoded_path(project_id)}")
        project = payload.get("project")
        if not isinstance(project, dict) or project.get("id") != project_id:
            raise NeonApiError("Neon API response did not contain the requested project.")
        return payload

    def create_project(
        self, name: str, region_id: str, database_name: str, role_name: str
    ) -> dict[str, Any]:
        return self.request(
            "POST",
            "/projects",
            payload={
                "project": {
                    "name": name,
                    "region_id": region_id,
                    "branch": {
                        "name": "main",
                        "database_name": database_name,
                        "role_name": role_name,
                    },
                }
            },
        )

    def list_branches(self, project_id: str) -> list[dict[str, Any]]:
        payload = self.request("GET", f"/projects/{_encoded_path(project_id)}/branches")
        branches = payload.get("branches")
        if not isinstance(branches, list) or not all(
            isinstance(branch, dict) for branch in branches
        ):
            raise NeonApiError("Neon API returned an invalid branch list.")
        return branches

    def list_databases(self, project_id: str, branch_id: str) -> list[dict[str, Any]]:
        payload = self.request(
            "GET",
            f"/projects/{_encoded_path(project_id, 'branches', branch_id, 'databases')}",
        )
        databases = payload.get("databases")
        if not isinstance(databases, list) or not all(
            isinstance(database, dict) for database in databases
        ):
            raise NeonApiError("Neon API returned an invalid database list.")
        return databases

    def create_database(
        self, project_id: str, branch_id: str, name: str, owner_name: str
    ) -> dict[str, Any]:
        return self.request(
            "POST",
            f"/projects/{_encoded_path(project_id, 'branches', branch_id, 'databases')}",
            payload={"database": {"name": name, "owner_name": owner_name}},
        )

    def list_roles(self, project_id: str, branch_id: str) -> list[dict[str, Any]]:
        payload = self.request(
            "GET",
            f"/projects/{_encoded_path(project_id, 'branches', branch_id, 'roles')}",
        )
        roles = payload.get("roles")
        if not isinstance(roles, list) or not all(
            isinstance(role, dict) for role in roles
        ):
            raise NeonApiError("Neon API returned an invalid role list.")
        return roles

    def create_role(self, project_id: str, branch_id: str, name: str) -> dict[str, Any]:
        return self.request(
            "POST",
            f"/projects/{_encoded_path(project_id, 'branches', branch_id, 'roles')}",
            payload={"role": {"name": name}},
        )

    def list_endpoints(self, project_id: str, branch_id: str) -> list[dict[str, Any]]:
        payload = self.request(
            "GET",
            f"/projects/{_encoded_path(project_id, 'branches', branch_id, 'endpoints')}",
        )
        endpoints = payload.get("endpoints")
        if not isinstance(endpoints, list) or not all(
            isinstance(endpoint, dict) for endpoint in endpoints
        ):
            raise NeonApiError("Neon API returned an invalid endpoint list.")
        return endpoints

    def connection_uri(
        self,
        project_id: str,
        branch_id: str,
        endpoint_id: str,
        database_name: str,
        role_name: str,
    ) -> str:
        payload = self.request(
            "GET",
            f"/projects/{_encoded_path(project_id, 'connection_uri')}",
            query={
                "branch_id": branch_id,
                "endpoint_id": endpoint_id,
                "database_name": database_name,
                "role_name": role_name,
            },
        )
        uri = payload.get("uri")
        if not isinstance(uri, str) or not uri.startswith(
            ("postgres://", "postgresql://")
        ):
            raise NeonApiError("Neon API did not return a PostgreSQL connection URI.")
        parsed = urlsplit(uri)
        if not parsed.hostname:
            raise NeonApiError("Neon API returned an invalid PostgreSQL connection URI.")
        query = parse_qsl(parsed.query, keep_blank_values=True)
        sslmodes = [value.lower() for key, value in query if key == "sslmode"]
        if "disable" in sslmodes:
            raise NeonApiError("Neon API returned a connection URI with TLS disabled.")
        if not sslmodes:
            query.append(("sslmode", "require"))
        elif any(mode not in {"require", "verify-ca", "verify-full"} for mode in sslmodes):
            query = [
                (key, "require" if key == "sslmode" else value)
                for key, value in query
            ]
        return urlunsplit(
            (parsed.scheme, parsed.netloc, parsed.path, urlencode(query), parsed.fragment)
        )

    def wait_for_operations(
        self,
        project_id: str,
        operations: list[dict[str, Any]],
        *,
        timeout: float = 300.0,
    ) -> None:
        deadline = time.monotonic() + timeout
        for operation in operations:
            operation_id = operation.get("id")
            if not isinstance(operation_id, str):
                raise NeonApiError("Neon API returned an operation without an ID.")
            status = operation.get("status")
            while status not in {"finished", "failed", "cancelled"}:
                if time.monotonic() >= deadline:
                    raise NeonApiError("Timed out waiting for Neon provisioning.")
                time.sleep(1)
                payload = self.request(
                    "GET",
                    f"/projects/{_encoded_path(project_id, 'operations', operation_id)}",
                )
                current = payload.get("operation")
                if not isinstance(current, dict):
                    raise NeonApiError("Neon API returned an invalid operation status.")
                status = current.get("status")
            if status != "finished":
                raise NeonApiError("A Neon provisioning operation did not complete.")

    def delete_project(self, project_id: str) -> None:
        self.request("DELETE", f"/projects/{_encoded_path(project_id)}")


def project_summary(
    config: dict[str, str], client: NeonClient, project_id: str | None = None
) -> dict[str, str]:
    requested_id = project_id or config["project_id"]
    if not requested_id:
        raise ConfigError("No Neon project ID is configured or recorded locally.")
    payload = client.get_project(requested_id)
    project = payload["project"]
    region_id = project.get("region_id")
    if region_id != config["region_id"]:
        raise NeonApiError("Configured region does not match the Neon project's region.")
    name = project.get("name")
    if not isinstance(name, str) or not name:
        raise NeonApiError("Neon API response did not contain a project name.")
    return {
        "project_id": requested_id,
        "name": name,
        "region_id": region_id,
        "database_name": config["database_name"],
        "application_role": config["application_role"],
    }


def read_state(path: Path) -> dict[str, str] | None:
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError) as exc:
        raise ConfigError("Cannot read the local Neon ownership state.") from exc
    if (
        not isinstance(state, dict)
        or state.get("owner") != STATE_OWNER
        or not isinstance(state.get("project_id"), str)
        or not PROJECT_ID_PATTERN.fullmatch(state["project_id"])
        or not isinstance(state.get("region_id"), str)
    ):
        raise ConfigError("Local Neon ownership state is invalid.")
    return state


def write_private_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ConfigError("Refusing to write a private file through a symbolic link.")
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            os.fchmod(temporary.fileno(), stat.S_IRUSR | stat.S_IWUSR)
            json.dump(payload, temporary, indent=2)
            temporary.write("\n")
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def _project_id_from_create(payload: dict[str, Any]) -> str:
    project = payload.get("project")
    if not isinstance(project, dict):
        raise NeonApiError("Neon API response did not contain the created project.")
    project_id = project.get("id")
    if not isinstance(project_id, str) or not PROJECT_ID_PATTERN.fullmatch(project_id):
        raise NeonApiError("Neon API returned an invalid project ID.")
    return project_id


def _select_branch(
    config: dict[str, str],
    project_id: str,
    client: NeonClient,
    created_payload: dict[str, Any] | None,
) -> str:
    if config["branch_id"]:
        branch_id = config["branch_id"]
        branch = client.request(
            "GET",
            f"/projects/{_encoded_path(project_id, 'branches', branch_id)}",
        ).get("branch")
        if not isinstance(branch, dict) or branch.get("id") != branch_id:
            raise NeonApiError("Configured branch does not belong to the selected project.")
        return branch_id
    if created_payload is not None:
        branch = created_payload.get("branch")
        if isinstance(branch, dict) and isinstance(branch.get("id"), str):
            return branch["id"]
    branches = client.list_branches(project_id)
    default_branch = next(
        (branch for branch in branches if branch.get("default") is True), None
    )
    if default_branch is None or not isinstance(default_branch.get("id"), str):
        raise NeonApiError("Neon project does not have a discoverable default branch.")
    return default_branch["id"]


def _ensure_database_and_role(
    config: dict[str, str],
    client: NeonClient,
    project_id: str,
    branch_id: str,
) -> None:
    roles = client.list_roles(project_id, branch_id)
    role = next(
        (item for item in roles if item.get("name") == config["application_role"]),
        None,
    )
    if role is None:
        created_role = client.create_role(
            project_id, branch_id, config["application_role"]
        )
        client.wait_for_operations(
            project_id, created_role.get("operations", [])
        )

    databases = client.list_databases(project_id, branch_id)
    database = next(
        (item for item in databases if item.get("name") == config["database_name"]),
        None,
    )
    if database is None:
        created_database = client.create_database(
            project_id,
            branch_id,
            config["database_name"],
            config["application_role"],
        )
        client.wait_for_operations(
            project_id, created_database.get("operations", [])
        )
    elif database.get("owner_name") != config["application_role"]:
        raise ConfigError(
            "The configured database exists with a different owner; "
            "no ownership changes were made."
        )


def setup_project(
    config: dict[str, str],
    client: NeonClient,
    state_path: Path,
    credentials_path: Path,
    *,
    confirm_create: str | None,
    confirm_existing_project: str | None,
) -> dict[str, str]:
    state = read_state(state_path)
    credential_path = str(credentials_path.expanduser().resolve())
    created_payload: dict[str, Any] | None = None
    if config["mode"] == "create":
        if state is None:
            if confirm_create != config["project_name"]:
                raise ConfigError(
                    "Creating a Neon project requires "
                    "--confirm-create matching project_name."
                )
            created_payload = client.create_project(
                config["project_name"],
                config["region_id"],
                config["database_name"],
                config["application_role"],
            )
            project_id = _project_id_from_create(created_payload)
            state = {
                "owner": STATE_OWNER,
                "project_id": project_id,
                "project_name": config["project_name"],
                "region_id": config["region_id"],
                "credentials_file": credential_path,
            }
            write_private_json(state_path, state)
            client.wait_for_operations(
                project_id, created_payload.get("operations", [])
            )
        else:
            if state["region_id"] != config["region_id"]:
                raise ConfigError("Local project ownership state region does not match config.")
            if state.get("project_name") != config["project_name"]:
                raise ConfigError(
                    "Local project ownership state name does not match config."
                )
            if state.get("credentials_file") not in {None, credential_path}:
                raise ConfigError(
                    "Credentials file differs from the path recorded in local state."
                )
            if (
                config["project_id"]
                and config["project_id"] != state["project_id"]
            ):
                raise ConfigError(
                    "Configured project ID does not match the locally recorded project."
                )
            project_id = state["project_id"]
    else:
        project_id = config["project_id"]
        if confirm_existing_project != project_id:
            raise ConfigError(
                "Setting up an existing Neon project requires "
                "--confirm-existing-project matching project_id."
            )

    summary = project_summary(config, client, project_id)
    branch_id = _select_branch(config, project_id, client, created_payload)
    _ensure_database_and_role(config, client, project_id, branch_id)
    endpoints = client.list_endpoints(project_id, branch_id)
    endpoint = next(
        (
            item
            for item in endpoints
            if item.get("type") == "read_write"
            and item.get("disabled") is not True
            and isinstance(item.get("id"), str)
        ),
        None,
    )
    if endpoint is None:
        raise NeonApiError("Neon project has no enabled read-write endpoint.")
    database_url = client.connection_uri(
        project_id,
        branch_id,
        endpoint["id"],
        config["database_name"],
        config["application_role"],
    )
    write_private_json(
        credentials_path,
        {
            "project_id": project_id,
            "branch_id": branch_id,
            "database_name": config["database_name"],
            "application_role": config["application_role"],
            "database_url": database_url,
        },
    )
    if state is not None:
        state["credentials_file"] = credential_path
        write_private_json(state_path, state)
    summary["branch_id"] = branch_id
    return summary


def destroy_created_project(
    config: dict[str, str],
    client: NeonClient,
    state_path: Path,
    credentials_path: Path,
    confirm_project_id: str | None,
) -> str:
    state = read_state(state_path)
    if state is None:
        raise ConfigError(
            "No locally recorded tool-created Neon project exists; "
            "existing projects are never deleted by this command."
        )
    project_id = state["project_id"]
    if state["region_id"] != config["region_id"]:
        raise ConfigError("Local project ownership state region does not match config.")
    if state.get("project_name") != config["project_name"]:
        raise ConfigError("Local project ownership state name does not match config.")
    recorded_credentials = state.get("credentials_file")
    if recorded_credentials and Path(recorded_credentials).expanduser().resolve() != (
        credentials_path.expanduser().resolve()
    ):
        raise ConfigError(
            "Credentials file does not match the path recorded in local state."
        )
    if config["project_id"] and config["project_id"] != project_id:
        raise ConfigError(
            "Configured project ID does not match the locally recorded project."
        )
    if confirm_project_id != project_id:
        raise ConfigError(
            "Deleting the tool-created Neon project requires "
            "--confirm-project-id matching its recorded project ID."
        )

    try:
        client.delete_project(project_id)
    except NeonApiError as exc:
        if exc.status_code != 404:
            raise
    state_path.unlink(missing_ok=True)
    credentials_path.unlink(missing_ok=True)
    return project_id


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--state-file", type=Path, default=DEFAULT_STATE_FILE)
    parser.add_argument(
        "--credentials-file", type=Path, default=DEFAULT_CREDENTIALS_FILE
    )
    parser.add_argument(
        "command",
        choices=("validate", "status", "setup", "destroy"),
        help="validate, inspect, provision, or remove a tool-created Neon project",
    )
    parser.add_argument(
        "--confirm-create",
        help="exact project_name confirmation required to create a Neon project",
    )
    parser.add_argument(
        "--confirm-existing-project",
        help="exact project_id confirmation required to modify an existing project",
    )
    parser.add_argument(
        "--confirm-project-id",
        help="exact locally recorded project_id confirmation required for destroy",
    )
    args = parser.parse_args(argv)

    try:
        config = load_config(args.config)
        if args.command == "validate":
            print("Configuration is valid (non-secret fields only).")
            return 0

        state = read_state(args.state_file)
        if args.command == "status":
            project_id = config["project_id"]
            if config["mode"] == "create":
                if state is None:
                    raise ConfigError(
                        "No project has been created for this config yet."
                    )
                project_id = state["project_id"]
            api_key = os.environ.get("NEON_API_KEY", "")
            if not api_key:
                raise ConfigError(
                    "Set NEON_API_KEY in the process environment to run status."
                )
            summary = project_summary(config, NeonClient(api_key), project_id)
            print(json.dumps(summary, indent=2))
            return 0

        api_key = os.environ.get("NEON_API_KEY", "")
        if not api_key:
            raise ConfigError(
                f"Set NEON_API_KEY in the process environment to run {args.command}."
            )
        client = NeonClient(api_key)
        if args.command == "setup":
            summary = setup_project(
                config,
                client,
                args.state_file,
                args.credentials_file,
                confirm_create=args.confirm_create,
                confirm_existing_project=args.confirm_existing_project,
            )
            print(json.dumps(summary, indent=2))
            print(
                "Connection credentials were written to the configured local "
                "credentials file with owner-only permissions."
            )
            return 0

        project_id = destroy_created_project(
            config,
            client,
            args.state_file,
            args.credentials_file,
            args.confirm_project_id,
        )
        print(
            f"Tool-created Neon project {project_id} was deleted; "
            "local state and credentials were removed."
        )
        return 0
    except (ConfigError, NeonApiError, ValueError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())

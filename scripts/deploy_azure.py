#!/usr/bin/env python3
"""Deploy prebuilt Agent Gateway images to a dedicated Azure resource group."""

from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit


ROOT = Path(__file__).resolve().parents[1]
TEMPLATE = ROOT / "deploy" / "azure" / "main.bicep"
MANAGED_BY = "agent-gateway-runtime-azure"
KEY_VAULT_SECRETS_USER = "Key Vault Secrets User"
CONTAINER_APPS_CONTRIBUTOR = "Container Apps Contributor"
SECRET_NAMES = {
    "database_url": "database-url",
    "jwt_secret": "jwt-secret",
    "gateway_admin_token": "gateway-admin-token",
    "licence_token": "licence-token",
    "oidc_client_secret": "oidc-client-secret",
}
IMAGE_KEYS = ("authz", "gateway", "tokensvc", "web")
UUID_PATTERN = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
IMAGE_PATTERN = re.compile(
    r"^[a-z0-9][a-z0-9.-]*(?::[0-9]{1,5})?/"
    r"[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?"
    r"(?:/[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?)*@sha256:[0-9a-f]{64}$"
)


class AzureError(RuntimeError):
    pass


def run(
    args: list[str],
    *,
    capture: bool = True,
    check: bool = True,
    input_text: str | None = None,
) -> str:
    result = subprocess.run(
        args,
        check=False,
        text=True,
        input=input_text,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode:
        detail = (result.stderr or result.stdout or "").strip()
        raise AzureError(f"Command failed ({result.returncode}): {args[0]} {args[1]}\n{detail}")
    if not capture:
        if result.stdout:
            print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, end="", file=sys.stderr)
    return result.stdout.strip() if capture and result.stdout else ""


def run_json(args: list[str]) -> Any:
    output = run(args)
    try:
        return json.loads(output)
    except json.JSONDecodeError as exc:
        raise AzureError(f"Azure CLI returned invalid JSON for `{args[0]} {args[1]}`") from exc


def load_config(path: Path) -> dict[str, Any]:
    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except OSError as exc:
        raise AzureError(f"Cannot read config file: {path}") from exc
    except json.JSONDecodeError as exc:
        raise AzureError(f"Invalid JSON in config file: {path}: {exc}") from exc
    if not isinstance(config, dict):
        raise AzureError("The config file must contain a JSON object.")
    return config


def validate_config(config: dict[str, Any], *, require_images: bool = True) -> list[str]:
    errors: list[str] = []
    required = (
        "subscription_id",
        "tenant_id",
        "location",
        "resource_group",
        "name_prefix",
        "key_vault_name",
        "key_vault_resource_group",
        "postgres_namespace",
        "oidc_issuer_url",
        "oidc_client_id",
        "web_admin_emails",
        "images",
    )
    for key in required:
        if key not in config:
            errors.append(f"Missing config field: {key}")
    if errors:
        return errors

    for key in ("subscription_id", "tenant_id", "oidc_client_id"):
        if not isinstance(config[key], str) or not UUID_PATTERN.fullmatch(config[key]):
            errors.append(f"{key} must be a UUID.")

    for key in (
        "location",
        "resource_group",
        "key_vault_resource_group",
        "postgres_namespace",
    ):
        if not isinstance(config[key], str) or not config[key].strip():
            errors.append(f"{key} must be a non-empty string.")
    vault_name = config["key_vault_name"]
    if not isinstance(vault_name, str) or not re.fullmatch(
        r"[A-Za-z0-9](?:[A-Za-z0-9-]{1,22}[A-Za-z0-9])", vault_name
    ) or "--" in vault_name:
        errors.append("key_vault_name must be 3-24 letters, digits, or single hyphens.")

    prefix = config["name_prefix"]
    if not isinstance(prefix, str) or not 2 <= len(prefix) <= 13 or not re.fullmatch(
        r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*", prefix
    ):
        errors.append("name_prefix must be 2-13 lowercase letters, digits, or hyphens and start with a letter.")
    elif all(
        isinstance(config[key], str)
        for key in ("resource_group", "key_vault_resource_group")
    ) and (
        config["resource_group"].lower() == f"{prefix}-emotion-demos".lower()
        or config["key_vault_resource_group"].lower() == config["resource_group"].lower()
        or config["key_vault_resource_group"].lower() == f"{prefix}-emotion-demos".lower()
    ):
        errors.append("The app, Emotion, and external Key Vault resource groups must be different.")

    issuer = config["oidc_issuer_url"]
    if not isinstance(issuer, str) or not issuer.startswith("https://"):
        errors.append("oidc_issuer_url must use HTTPS.")
    if not isinstance(config["web_admin_emails"], str) or not config["web_admin_emails"].strip():
        errors.append("web_admin_emails must contain at least one administrator email.")

    images = config["images"]
    if not isinstance(images, dict):
        errors.append("images must be a JSON object.")
    else:
        for key in IMAGE_KEYS:
            image = images.get(key)
            if require_images and (not isinstance(image, str) or not IMAGE_PATTERN.fullmatch(image)):
                errors.append(
                    f"images.{key} must be a registry image pinned by a lowercase sha256 digest."
                )
    emotion_image = config.get("emotion_image")
    if require_images and (
        not isinstance(emotion_image, str) or not IMAGE_PATTERN.fullmatch(emotion_image)
    ):
        errors.append("emotion_image must be a registry image pinned by a lowercase sha256 digest.")
    registry = config.get(
        "private_registry",
        {"server": "", "username": "", "password_secret_name": "registry-password"},
    )
    if not isinstance(registry, dict):
        errors.append("private_registry must be a JSON object.")
    else:
        server = registry.get("server", "")
        username = registry.get("username", "")
        secret_name = registry.get("password_secret_name", "registry-password")
        if not all(isinstance(value, str) for value in (server, username, secret_name)):
            errors.append("private_registry values must be strings.")
        elif bool(server) != bool(username):
            errors.append("private_registry.server and private_registry.username must be set together.")
        elif server and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*(?::[0-9]{1,5})?", server):
            errors.append("private_registry.server must be a registry hostname, without a scheme or path.")
        elif server and not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,18}[a-z0-9])?", secret_name):
            errors.append("private_registry.password_secret_name must be a Key Vault secret name.")
        elif server and secret_name in SECRET_NAMES.values():
            errors.append("private_registry.password_secret_name must not collide with a runtime secret name.")
        elif server:
            references = [images.get(key) for key in IMAGE_KEYS] if isinstance(images, dict) else []
            for reference in references:
                if isinstance(reference, str) and IMAGE_PATTERN.fullmatch(reference):
                    image_host = reference.split("/", 1)[0].lower()
                    if image_host != server.lower():
                        errors.append(
                            "All image hosts must match private_registry.server when private pull credentials are configured."
                        )
                        break
    return errors


def ensure_azure_tools(*, require_bicep: bool) -> None:
    for executable in ("az",):
        if not any(
            os.access(Path(directory) / executable, os.X_OK)
            for directory in os.environ.get("PATH", "").split(os.pathsep)
        ):
            raise AzureError(f"Required executable not found on PATH: {executable}")
    if require_bicep:
        run(["az", "bicep", "version"])


def account(config: dict[str, Any]) -> dict[str, Any]:
    current = run_json(["az", "account", "show", "--output", "json"])
    if current.get("id", "").lower() != config["subscription_id"].lower():
        raise AzureError(
            "The active Azure subscription does not match subscription_id in the config. "
            "Select the intended subscription with `az account set` and retry."
        )
    if current.get("tenantId", "").lower() != config["tenant_id"].lower():
        raise AzureError(
            "The active Azure tenant does not match tenant_id in the config. "
            "Sign in to the intended tenant and retry."
        )
    return current


def require_owned_group(
    name: str,
    *,
    deployment: str,
    must_exist: bool,
) -> dict[str, Any] | None:
    exists = run(
        ["az", "group", "exists", "--name", name, "--output", "tsv"],
    ).lower()
    if exists == "false":
        if must_exist:
            raise AzureError(f"Resource group does not exist: {name}")
        return None
    if exists != "true":
        raise AzureError(f"Azure returned an unexpected existence result for resource group {name}.")
    group = run_json(["az", "group", "show", "--name", name, "--output", "json"])
    tags = group.get("tags") or {}
    if tags.get("managedBy") != MANAGED_BY or tags.get("deployment") != deployment:
        raise AzureError(
            f"Resource group {name} already exists and is not marked as managed by "
            f"{MANAGED_BY} for deployment {deployment}; refusing to modify or delete it."
        )
    return group


def get_vault(config: dict[str, Any]) -> dict[str, Any]:
    vault = run_json(
        [
            "az",
            "keyvault",
            "show",
            "--name",
            config["key_vault_name"],
            "--resource-group",
            config["key_vault_resource_group"],
            "--output",
            "json",
        ]
    )
    if not (vault.get("properties") or {}).get("enableRbacAuthorization", False):
        raise AzureError(
            "The configured Key Vault must use Azure RBAC authorization before it can "
            "grant the runtime managed identity access."
        )
    return vault


def secret_states_in_vault(config: dict[str, Any]) -> dict[str, bool]:
    secrets_in_vault = run_json(
        [
            "az",
            "keyvault",
            "secret",
            "list",
            "--vault-name",
            config["key_vault_name"],
            "--query",
            "[].{name:name,enabled:attributes.enabled}",
            "--output",
            "json",
        ]
    )
    return {
        item["name"]: item.get("enabled") is True
        for item in (secrets_in_vault or [])
        if item.get("name")
    }


def secret_names_in_vault(config: dict[str, Any]) -> set[str]:
    return {
        name
        for name, enabled in secret_states_in_vault(config).items()
        if enabled
    }


def secure_file_bytes(path: Path) -> bytes:
    try:
        stat = path.stat()
    except OSError as exc:
        raise AzureError(f"Cannot read secret file: {path}") from exc
    if not path.is_file() or path.is_symlink():
        raise AzureError(f"Secret input must be a regular, non-symlink file: {path}")
    if stat.st_uid != os.getuid() or stat.st_mode & 0o077:
        raise AzureError(f"Secret file must be owned by the current user with mode 0600 or stricter: {path}")
    try:
        data = path.read_bytes().strip()
    except OSError as exc:
        raise AzureError(f"Cannot read secret file: {path}") from exc
    if not data:
        raise AzureError(f"Secret file is empty: {path}")
    return data


def neon_database_url(path: Path) -> bytes:
    raw = secure_file_bytes(path)
    try:
        credentials = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise AzureError(f"Neon credential file is not valid JSON: {path}") from exc
    if not isinstance(credentials, dict):
        raise AzureError(f"Neon credential file must contain a JSON object: {path}")
    database_url = credentials.get("database_url")
    if not isinstance(database_url, str) or not database_url.strip():
        raise AzureError(f"Neon credential file must include a non-empty database_url: {path}")
    database_url = database_url.strip()
    try:
        parsed = urlsplit(database_url)
    except ValueError as exc:
        raise AzureError(f"Neon database_url is not a valid PostgreSQL connection URL: {path}") from exc
    ssl_modes = parse_qs(parsed.query).get("sslmode", [])
    if parsed.scheme not in {"postgres", "postgresql"} or not parsed.hostname:
        raise AzureError(f"Neon database_url must be a PostgreSQL connection URL: {path}")
    if not ssl_modes or any(mode.lower() not in {"require", "verify-ca", "verify-full"} for mode in ssl_modes):
        raise AzureError(f"Neon database_url must require TLS with a secure sslmode: {path}")
    return database_url.encode("utf-8")


def upload_secret(config: dict[str, Any], name: str, value: bytes) -> None:
    temp_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(prefix="agw-azure-secret-", delete=False) as secret_file:
            temp_path = Path(secret_file.name)
            os.chmod(temp_path, 0o600)
            secret_file.write(value)
        run(
            [
                "az",
                "keyvault",
                "secret",
                "set",
                "--vault-name",
                config["key_vault_name"],
                "--name",
                name,
                "--file",
                str(temp_path),
                "--tags",
                f"managedBy={MANAGED_BY}",
                f"deployment={config['name_prefix']}",
                "--output",
                "none",
            ],
            capture=False,
        )
    finally:
        if temp_path:
            temp_path.unlink(missing_ok=True)


def confirm(prompt: str, expected: str) -> None:
    try:
        answer = input(f"{prompt}\nType `{expected}` to continue: ").strip()
    except EOFError as exc:
        raise AzureError("Interactive confirmation is required; no changes were made.") from exc
    if answer != expected:
        raise AzureError("Confirmation did not match; no further changes were made.")


def assignment_id(principal_id: str, scope: str, role_name: str) -> str:
    key = f"{scope.lower()}|{principal_id.lower()}|{role_name}"
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"agent-gateway-runtime-azure:{key}"))


def role_assignments(principal_id: str, scope: str, role_name: str) -> list[dict[str, Any]]:
    assignments = run_json(
        [
            "az",
            "role",
            "assignment",
            "list",
            "--assignee-object-id",
            principal_id,
            "--scope",
            scope,
            "--all",
            "--output",
            "json",
        ]
    )
    return [
        item
        for item in (assignments or [])
        if item.get("principalId", "").lower() == principal_id.lower()
        and item.get("roleDefinitionName") == role_name
        and item.get("scope", "").lower() == scope.lower()
    ]


def ensure_role(principal_id: str, scope: str, role_name: str) -> None:
    if role_assignments(principal_id, scope, role_name):
        return
    run(
        [
            "az",
            "role",
            "assignment",
            "create",
            "--assignee-object-id",
            principal_id,
            "--assignee-principal-type",
            "ServicePrincipal",
            "--role",
            role_name,
            "--name",
            assignment_id(principal_id, scope, role_name),
            "--scope",
            scope,
            "--output",
            "none",
        ],
        capture=False,
    )


def identity(config: dict[str, Any], *, create: bool) -> dict[str, Any] | None:
    name = f"{config['name_prefix']}-identity"
    identities = run_json(
        [
            "az",
            "identity",
            "list",
            "--resource-group",
            config["resource_group"],
            "--query",
            "[].{name:name,principalId:principalId,clientId:clientId,id:id,tags:tags}",
            "--output",
            "json",
        ]
    )
    current = next((item for item in identities if item.get("name") == name), None)
    if current:
        tags = current.get("tags") or {}
        if tags.get("managedBy") != MANAGED_BY or tags.get("deployment") != config["name_prefix"]:
            raise AzureError(f"Managed identity {name} exists but is not marked as runtime-managed.")
        return current
    if not create:
        return None
    return run_json(
        [
            "az",
            "identity",
            "create",
            "--name",
            name,
            "--resource-group",
            config["resource_group"],
            "--location",
            config["location"],
            "--tags",
            f"managedBy={MANAGED_BY}",
            f"deployment={config['name_prefix']}",
            "--output",
            "json",
        ]
    )


def bicep_parameters(
    config: dict[str, Any],
    vault: dict[str, Any],
    identity_client_id: str,
) -> dict[str, Any]:
    vault_uri = (vault.get("properties") or {}).get("vaultUri", "").rstrip("/")
    if not vault_uri.startswith("https://"):
        raise AzureError("Azure did not return a valid HTTPS Key Vault URI.")
    return {
        "namePrefix": {"value": config["name_prefix"]},
        "location": {"value": config["location"]},
        "subscriptionId": {"value": config["subscription_id"]},
        "emotionResourceGroupName": {"value": f"{config['name_prefix']}-emotion-demos"},
        "runtimeIdentityName": {"value": f"{config['name_prefix']}-identity"},
        "runtimeIdentityClientId": {"value": identity_client_id},
        "keyVaultUri": {"value": vault_uri},
        "secretNames": {
            "value": {
                "databaseUrl": SECRET_NAMES["database_url"],
                "jwtSecret": SECRET_NAMES["jwt_secret"],
                "gatewayAdminToken": SECRET_NAMES["gateway_admin_token"],
                "licenceToken": SECRET_NAMES["licence_token"],
                "oidcClientSecret": SECRET_NAMES["oidc_client_secret"],
            }
        },
        "postgresNamespace": {"value": config["postgres_namespace"]},
        "oidcIssuerUrl": {"value": config["oidc_issuer_url"].rstrip("/")},
        "oidcClientId": {"value": config["oidc_client_id"]},
        "webAdminEmails": {"value": config["web_admin_emails"]},
        "images": {"value": config["images"]},
        "emotionImage": {"value": config["emotion_image"]},
        "privateRegistry": {
            "value": {
                "server": config.get("private_registry", {}).get("server", ""),
                "username": config.get("private_registry", {}).get("username", ""),
                "passwordSecretName": config.get("private_registry", {}).get(
                    "password_secret_name", "registry-password"
                ),
            }
        },
    }


def deployment_args(
    config: dict[str, Any],
    vault: dict[str, Any],
    identity_client_id: str,
) -> list[str]:
    parameters = json.dumps(bicep_parameters(config, vault, identity_client_id))
    return [
        "az",
        "deployment",
        "group",
        "what-if",
        "--resource-group",
        config["resource_group"],
        "--name",
        f"{config['name_prefix']}-preview",
        "--template-file",
        str(TEMPLATE),
        "--parameters",
        parameters,
        "--result-format",
        "FullResourcePayloads",
    ]


def show_plan(config: dict[str, Any], vault: dict[str, Any], *, preview: bool) -> None:
    print("Azure deployment plan")
    print(f"  Subscription: {config['subscription_id']}")
    print(f"  Tenant:       {config['tenant_id']}")
    print(f"  Region:       {config['location']}")
    print(f"  App RG:       {config['resource_group']}")
    print(f"  Emotion RG:   {config['name_prefix']}-emotion-demos")
    print(f"  Key Vault:    {config['key_vault_name']} (existing; not deleted)")
    for key in IMAGE_KEYS:
        print(f"  {key} image: {config['images'][key]}")
    print("  Resources: Container Apps environment and four Container Apps (Azure Monitor logs).")
    if preview and require_owned_group(
        config["resource_group"],
        deployment=config["name_prefix"],
        must_exist=False,
    ):
        runtime_identity = identity(config, create=False)
        if runtime_identity and runtime_identity.get("clientId"):
            run(deployment_args(config, vault, runtime_identity["clientId"]), capture=False)
        else:
            print("  Managed identity is not present; full Azure What-If preview will run during apply.")
    elif preview:
        print("  Resource group is new; Azure What-If preview will run after the guarded RG creation.")


def apply(config: dict[str, Any], vault: dict[str, Any]) -> None:
    app_rg = config["resource_group"]
    emotion_rg = f"{config['name_prefix']}-emotion-demos"
    existing_app_group = require_owned_group(
        app_rg,
        deployment=config["name_prefix"],
        must_exist=False,
    )
    existing_emotion_group = require_owned_group(
        emotion_rg,
        deployment=config["name_prefix"],
        must_exist=False,
    )
    if existing_app_group:
        print(f"Existing app resource group is owned by {MANAGED_BY}.")
    if existing_emotion_group:
        print(f"Existing Emotion resource group is owned by {MANAGED_BY}.")
    confirm("This will create or update the dedicated Azure deployment shown above.", f"APPLY {app_rg}")

    if not existing_app_group:
        run(
            [
                "az",
                "group",
                "create",
                "--name",
                app_rg,
                "--location",
                config["location"],
                "--tags",
                f"managedBy={MANAGED_BY}",
                "application=agent-gateway",
                f"deployment={config['name_prefix']}",
                "--output",
                "none",
            ],
            capture=False,
        )
    if not existing_emotion_group:
        run(
            [
                "az",
                "group",
                "create",
                "--name",
                emotion_rg,
                "--location",
                config["location"],
                "--tags",
                f"managedBy={MANAGED_BY}",
                "application=agent-gateway",
                "purpose=wizard-created-emotion-demos",
                f"deployment={config['name_prefix']}",
                "--output",
                "none",
            ],
            capture=False,
        )
    runtime_identity = identity(config, create=True)
    if runtime_identity is None:
        raise AzureError("Azure did not return the runtime managed identity.")
    principal_id = runtime_identity.get("principalId")
    if not principal_id:
        raise AzureError("Azure did not return a principal ID for the runtime managed identity.")
    identity_client_id = runtime_identity.get("clientId")
    if not identity_client_id:
        raise AzureError("Azure did not return a client ID for the runtime managed identity.")
    vault_scope = vault.get("id")
    if not vault_scope:
        raise AzureError("Azure did not return the configured Key Vault resource ID.")
    ensure_role(principal_id, vault_scope, KEY_VAULT_SECRETS_USER)
    time.sleep(20)

    print("\nAzure Resource Manager What-If preview:")
    run(deployment_args(config, vault, identity_client_id), capture=False)
    confirm("Review the What-If output. Continue to deploy its changes?", f"DEPLOY {app_rg}")
    result = run_json(
        [
            "az",
            "deployment",
            "group",
            "create",
            "--resource-group",
            app_rg,
            "--name",
            f"{config['name_prefix']}-deployment",
            "--template-file",
            str(TEMPLATE),
            "--parameters",
            json.dumps(bicep_parameters(config, vault, identity_client_id)),
            "--output",
            "json",
        ]
    )
    outputs = result.get("properties", {}).get("outputs", {})
    environment_id = outputs.get("environmentId", {}).get("value")
    if not environment_id:
        raise AzureError("Deployment succeeded but did not return its Container Apps environment ID.")
    ensure_role(principal_id, f"/subscriptions/{config['subscription_id']}/resourceGroups/{emotion_rg}", CONTAINER_APPS_CONTRIBUTOR)
    ensure_role(principal_id, environment_id, CONTAINER_APPS_CONTRIBUTOR)
    web = run_json(
        [
            "az",
            "containerapp",
            "show",
            "--name",
            f"{config['name_prefix']}-web",
            "--resource-group",
            app_rg,
            "--query",
            "properties.configuration.ingress.fqdn",
            "--output",
            "json",
        ]
    )
    if not isinstance(web, str) or not web:
        raise AzureError("The web Container App has no HTTPS ingress hostname after deployment.")
    print("\nAzure Resource Manager deployment completed.")
    print(f"Console: https://{web}")
    print(f"OIDC redirect URI to register: https://{web}/oidc/callback")
    print("The Entra app registration must include that exact redirect URI.")
    print("Container image startup and application readiness still require live verification.")


def upload_secrets(
    config: dict[str, Any],
    *,
    neon_file: Path,
    licence_file: Path,
    oidc_secret_file: Path,
    registry_password_file: Path | None,
) -> None:
    vault = get_vault(config)
    if not vault.get("id"):
        raise AzureError("Azure did not return the configured Key Vault resource ID.")
    secret_states = secret_states_in_vault(config)
    values = {
        SECRET_NAMES["database_url"]: neon_database_url(neon_file),
        SECRET_NAMES["licence_token"]: secure_file_bytes(licence_file),
        SECRET_NAMES["oidc_client_secret"]: secure_file_bytes(oidc_secret_file),
    }
    registry = config.get("private_registry", {})
    registry_server = registry.get("server", "")
    if registry_server:
        if registry_password_file is None:
            raise AzureError(
                "Private registry credentials are configured; supply --registry-password-file."
            )
        values[registry.get("password_secret_name", "registry-password")] = secure_file_bytes(
            registry_password_file
        )
    elif registry_password_file is not None:
        raise AzureError(
            "--registry-password-file was supplied, but private_registry is not configured."
        )
    required_names = set(SECRET_NAMES.values())
    if registry_server:
        required_names.add(registry.get("password_secret_name", "registry-password"))
    disabled = sorted(name for name in required_names if secret_states.get(name) is False)
    if disabled:
        raise AzureError(
            "Key Vault contains disabled secrets required by this deployment: "
            + ", ".join(disabled)
            + ". Enable or replace them through your approved Key Vault process."
        )
    existing = {name for name, enabled in secret_states.items() if enabled}
    if SECRET_NAMES["jwt_secret"] not in existing:
        values[SECRET_NAMES["jwt_secret"]] = secrets.token_urlsafe(48).encode("ascii")
    if SECRET_NAMES["gateway_admin_token"] not in existing:
        values[SECRET_NAMES["gateway_admin_token"]] = secrets.token_urlsafe(48).encode("ascii")
    for name, value in values.items():
        if name in existing:
            print(f"Keeping existing Key Vault secret: {name}")
        else:
            upload_secret(config, name, value)
            print(f"Uploaded Key Vault secret: {name}")


def destroy(config: dict[str, Any]) -> None:
    app_rg = config["resource_group"]
    emotion_rg = f"{config['name_prefix']}-emotion-demos"
    app_group = require_owned_group(
        app_rg,
        deployment=config["name_prefix"],
        must_exist=True,
    )
    if app_group is None:
        raise AzureError(f"Refusing to delete resource group without ownership marker: {app_rg}")
    emotion_group = require_owned_group(
        emotion_rg,
        deployment=config["name_prefix"],
        must_exist=False,
    )
    runtime_identity = identity(config, create=False)
    principal_id = runtime_identity.get("principalId") if runtime_identity else None
    vaults = run_json(
        [
            "az",
            "keyvault",
            "list",
            "--resource-group",
            config["key_vault_resource_group"],
            "--query",
            f"[?name=='{config['key_vault_name']}'] | [0]",
            "--output",
            "json",
        ]
    )
    vault_scope = vaults.get("id") if vaults else None

    resources = run_json(
        [
            "az",
            "resource",
            "list",
            "--resource-group",
            app_rg,
            "--query",
            "[].{name:name,type:type,tags:tags}",
            "--output",
            "json",
        ]
    )
    print(f"Resources in {app_rg}:")
    for resource in resources or []:
        print(f"  {resource.get('type')}: {resource.get('name')}")
    if emotion_group:
        emotion_resources = run_json(
            [
                "az",
                "resource",
                "list",
                "--resource-group",
                emotion_rg,
                "--query",
                "[].{name:name,type:type,tags:tags}",
                "--output",
                "json",
            ]
        )
        print(f"Resources in {emotion_rg}:")
        for resource in emotion_resources or []:
            print(f"  {resource.get('type')}: {resource.get('name')}")
    vault_secrets = (
        run_json(
            [
                "az",
                "keyvault",
                "secret",
                "list",
                "--vault-name",
                config["key_vault_name"],
                "--query",
                "[].{name:name,tags:tags}",
                "--output",
                "json",
            ]
        )
        if vault_scope
        else []
    )
    owned_secrets = [
        item["name"]
        for item in (vault_secrets or [])
        if (item.get("tags") or {}).get("managedBy") == MANAGED_BY
        and (item.get("tags") or {}).get("deployment") == config["name_prefix"]
    ]
    if vault_scope:
        print(f"The existing Key Vault itself will be preserved: {config['key_vault_name']}")
    else:
        print(f"Configured Key Vault is already absent: {config['key_vault_name']}")
    if owned_secrets:
        print("Key Vault secrets created by this deployment (will be deleted/soft-deleted):")
        for name in sorted(owned_secrets):
            print(f"  {name}")
    else:
        print("No Key Vault secrets tagged as created by this deployment were found.")
    confirm(
        "This deletes every listed resource in these dedicated resource groups and "
        "soft-deletes the listed deployment-created Key Vault secrets. Confirm they contain "
        "no data or resources you need.",
        f"DESTROY {app_rg}",
    )

    for secret_name in sorted(owned_secrets):
        run(
            [
                "az",
                "keyvault",
                "secret",
                "delete",
                "--vault-name",
                config["key_vault_name"],
                "--name",
                secret_name,
                "--output",
                "none",
            ],
            capture=False,
        )
    assignments = (
        role_assignments(principal_id, vault_scope, KEY_VAULT_SECRETS_USER)
        if vault_scope and principal_id
        else []
    )
    owned_assignment_id = (
        assignment_id(principal_id, vault_scope, KEY_VAULT_SECRETS_USER)
        if vault_scope and principal_id
        else ""
    )
    for assignment in assignments:
        if assignment.get("name") != owned_assignment_id:
            continue
        run(
            ["az", "role", "assignment", "delete", "--ids", assignment["id"], "--output", "none"],
            capture=False,
        )
    if emotion_group:
        run(
            ["az", "group", "delete", "--name", emotion_rg, "--yes", "--no-wait"],
            capture=False,
        )
    run(
        ["az", "group", "delete", "--name", app_rg, "--yes", "--no-wait"],
        capture=False,
    )
    print(
        "Deletion requested. The Key Vault, Neon database, and Entra app registration were not deleted. "
        "Deleted Key Vault secrets may remain recoverable under the vault's soft-delete retention."
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=("validate", "plan", "apply", "upload-secrets", "destroy"),
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=ROOT / "deploy" / "azure" / "azure-config.json",
    )
    parser.add_argument("--neon-credentials-file", type=Path, default=ROOT / "config" / "neon-credentials.json")
    parser.add_argument("--licence-token-file", type=Path)
    parser.add_argument("--oidc-client-secret-file", type=Path)
    parser.add_argument("--registry-password-file", type=Path)
    args = parser.parse_args()

    try:
        config = load_config(args.config)
        errors = validate_config(config, require_images=args.action in {"plan", "apply"})
        if errors:
            raise AzureError("Invalid deployment config:\n- " + "\n- ".join(errors))
        if args.action == "validate":
            print(f"Config is structurally valid: {args.config}")
            print("Replace all example values and supply digest-pinned images before deployment.")
            return 0

        ensure_azure_tools(require_bicep=args.action in {"plan", "apply"})
        account(config)
        if args.action == "upload-secrets":
            vault = get_vault(config)
            if not args.licence_token_file or not args.oidc_client_secret_file:
                raise AzureError(
                    "upload-secrets requires --licence-token-file and --oidc-client-secret-file."
                )
            upload_secrets(
                config,
                neon_file=args.neon_credentials_file,
                licence_file=args.licence_token_file,
                oidc_secret_file=args.oidc_client_secret_file,
                registry_password_file=args.registry_password_file,
            )
        elif args.action == "plan":
            vault = get_vault(config)
            names = secret_names_in_vault(config)
            required_secrets = set(SECRET_NAMES.values())
            registry = config.get("private_registry", {})
            if registry.get("server"):
                required_secrets.add(registry.get("password_secret_name", "registry-password"))
            missing = sorted(required_secrets - names)
            if missing:
                raise AzureError("Missing Key Vault secrets: " + ", ".join(missing))
            show_plan(config, vault, preview=True)
        elif args.action == "apply":
            vault = get_vault(config)
            names = secret_names_in_vault(config)
            required_secrets = set(SECRET_NAMES.values())
            registry = config.get("private_registry", {})
            if registry.get("server"):
                required_secrets.add(registry.get("password_secret_name", "registry-password"))
            missing = sorted(required_secrets - names)
            if missing:
                raise AzureError("Missing Key Vault secrets: " + ", ".join(missing))
            show_plan(config, vault, preview=False)
            apply(config, vault)
        elif args.action == "destroy":
            destroy(config)
        return 0
    except AzureError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())

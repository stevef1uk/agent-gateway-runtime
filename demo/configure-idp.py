#!/usr/bin/env python3
"""Generate the ignored Dex configuration for a hardened Google/Microsoft setup."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import urlparse


DEMO_DIR = Path(__file__).resolve().parent
ENV_FILE = DEMO_DIR / ".env"
TEMPLATE = DEMO_DIR / "dex" / "config.yaml"
OUTPUT = DEMO_DIR / "dex" / "config.hardened.yaml"
MARKER = "# DEX_CONNECTOR_BLOCK"
REDIRECT_MARKER = "      # DEX_DYNAMIC_REDIRECTS"
QUICK_TUNNEL_URL = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com", re.IGNORECASE)


def read_env_file(path):
    values = {}
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        key, separator, value = line.partition("=")
        if not separator:
            continue
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key.strip()] = value
    return values


def setting(values, key):
    return os.environ.get(key) or values.get(key, "")


def write_env_values(path, updates):
    lines = path.read_text(encoding="utf-8").splitlines()
    written = set()
    output = []
    for line in lines:
        key, separator, _ = line.partition("=")
        key = key.strip()
        if key.startswith("export "):
            key = key[7:].strip()
        if separator and key in updates:
            output.append(f"{key}={updates[key]}")
            written.add(key)
        else:
            output.append(line)
    for key, value in updates.items():
        if key not in written:
            output.append(f"{key}={value}")

    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, delete=False
    ) as generated:
        generated.write("\n".join(output) + "\n")
        temporary_path = Path(generated.name)
    temporary_path.chmod(0o600)
    temporary_path.replace(path)
    path.chmod(0o600)


def discover_quick_tunnel_url():
    try:
        containers = subprocess.run(
            [
                "docker", "ps", "--filter",
                "ancestor=cloudflare/cloudflared:latest", "--format", "{{.ID}}",
            ],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.splitlines()
    except FileNotFoundError as error:
        raise SystemExit("Docker is required to detect the running Cloudflare tunnel") from error
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"Could not inspect running Docker containers: {error.stderr.strip()}") from error

    urls = set()
    for container_id in containers:
        try:
            logs = subprocess.run(
                ["docker", "logs", "--tail=100", container_id],
                check=True,
                capture_output=True,
                text=True,
            )
        except subprocess.CalledProcessError as error:
            raise SystemExit(
                f"Could not read logs for Cloudflare tunnel container {container_id}: "
                f"{error.stderr.strip()}"
            ) from error
        urls.update(QUICK_TUNNEL_URL.findall(logs.stdout + logs.stderr))

    if len(urls) > 1:
        found = "\n".join(sorted(urls))
        raise SystemExit(
            "More than one Cloudflare Quick Tunnel is running. Stop the others and "
            f"rerun this script; found:\n{found}"
        )
    if containers and not urls:
        raise SystemExit(
            "A cloudflare/cloudflared container is running, but its Quick Tunnel URL "
            "was not found in recent logs. Wait until it prints 'Your quick Tunnel "
            "has been created' and rerun this script."
        )
    return next(iter(urls), "")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--print-tunnel-url",
        action="store_true",
        help="detect the running Quick Tunnel, save its issuer/callback to .env, and print the provider redirect URI",
    )
    args = parser.parse_args()

    if args.print_tunnel_url:
        tunnel_url = discover_quick_tunnel_url()
        if not tunnel_url:
            raise SystemExit(
                "No running cloudflare/cloudflared:latest tunnel was detected. "
                "Start the tunnel first, then rerun this command."
            )
        issuer_url = tunnel_url + "/dex"
        redirect_uri = issuer_url + "/callback"
        write_env_values(ENV_FILE, {
            "DEX_ISSUER_URL": issuer_url,
            "DEX_UPSTREAM_REDIRECT_URI": redirect_uri,
        })
        print(f"Detected Cloudflare Quick Tunnel: {tunnel_url}")
        print(f"Register this exact redirect URI with your IdP:\n{redirect_uri}")
        print("The matching issuer and callback have been saved to demo/.env.")
        return

    values = read_env_file(ENV_FILE)
    connector_id = setting(values, "OIDC_CONNECTOR_ID")
    client_id = setting(values, "DEX_UPSTREAM_CLIENT_ID")
    client_secret = setting(values, "DEX_UPSTREAM_CLIENT_SECRET")
    tunnel_url = discover_quick_tunnel_url()
    if tunnel_url:
        issuer_url = tunnel_url + "/dex"
        redirect_uri = issuer_url + "/callback"
        values["DEX_ISSUER_URL"] = issuer_url
        values["DEX_UPSTREAM_REDIRECT_URI"] = redirect_uri
        print(f"Detected running Cloudflare Quick Tunnel: {tunnel_url}")
        print(f"Register this exact redirect URI with your IdP:\n{redirect_uri}")
    else:
        issuer_url = setting(values, "DEX_ISSUER_URL").rstrip("/")
        redirect_uri = setting(values, "DEX_UPSTREAM_REDIRECT_URI")
        print(
            "No running cloudflare/cloudflared:latest tunnel was detected; "
            "using DEX_ISSUER_URL and DEX_UPSTREAM_REDIRECT_URI from demo/.env."
        )
    web_public_url = setting(values, "WEB_PUBLIC_URL") or "http://localhost:8083"

    if connector_id not in {"google", "microsoft"}:
        raise SystemExit("Set OIDC_CONNECTOR_ID to google or microsoft in demo/.env")
    missing = [
        name
        for name, value in (
            ("DEX_UPSTREAM_CLIENT_ID", client_id),
            ("DEX_UPSTREAM_CLIENT_SECRET", client_secret),
            ("DEX_ISSUER_URL", issuer_url),
            ("DEX_UPSTREAM_REDIRECT_URI", redirect_uri),
        )
        if not value
    ]
    if missing:
        raise SystemExit("Set " + ", ".join(missing) + " in demo/.env")
    parsed_uri = urlparse(redirect_uri)
    if parsed_uri.scheme not in {"http", "https"} or not parsed_uri.netloc:
        raise SystemExit("DEX_UPSTREAM_REDIRECT_URI must be an absolute HTTP(S) URL")
    parsed_issuer = urlparse(issuer_url)
    if (
        parsed_issuer.scheme != "https"
        or not parsed_issuer.netloc
        or parsed_issuer.query
        or parsed_issuer.fragment
    ):
        raise SystemExit("DEX_ISSUER_URL must be an HTTPS issuer URL without query or fragment")
    expected_redirect_uri = issuer_url + "/callback"
    if redirect_uri != expected_redirect_uri:
        raise SystemExit(
            "DEX_UPSTREAM_REDIRECT_URI must exactly match "
            f"DEX_ISSUER_URL + /callback ({expected_redirect_uri})"
        )

    redirect_bases = [(web_public_url, "/oidc/callback")]
    for key in ("OAUTH_PUBLIC_BASE", "OAUTH_PUBLIC_BASE_EMOTION"):
        base = setting(values, key)
        if base:
            redirect_bases.append((base, "/oauth/idpcallback"))
    if any(
        urlparse(base).scheme not in {"http", "https"} or not urlparse(base).netloc
        for base, _ in redirect_bases
    ):
        raise SystemExit("WEB_PUBLIC_URL and OAuth public bases must be absolute HTTP(S) URLs")

    provider = "Google" if connector_id == "google" else "Microsoft"
    connector = [
        "connectors:",
        f"  - type: {connector_id}",
        f"    id: {connector_id}",
        f"    name: {provider}",
        "    config:",
        f"      clientID: {json.dumps(client_id)}",
        f"      clientSecret: {json.dumps(client_secret)}",
        f"      redirectURI: {json.dumps(redirect_uri)}",
    ]
    if connector_id == "microsoft":
        connector.append("      tenant: common")

    template = TEMPLATE.read_text(encoding="utf-8")
    if template.count(MARKER) != 1:
        raise SystemExit(f"Expected exactly one connector marker in {TEMPLATE}")
    if template.count(REDIRECT_MARKER) != 1:
        raise SystemExit(f"Expected exactly one redirect marker in {TEMPLATE}")
    rendered = template.replace(MARKER, "\n".join(connector))
    issuer_marker = "issuer: DEX_ISSUER_URL"
    if rendered.count(issuer_marker) != 1:
        raise SystemExit(f"Expected exactly one issuer marker in {TEMPLATE}")
    rendered = rendered.replace(issuer_marker, f"issuer: {json.dumps(issuer_url)}")
    redirects = []
    existing_redirects = {
        "http://localhost:8083/oidc/callback",
        "http://127.0.0.1:8083/oidc/callback",
        "http://localhost:8080/oauth/idpcallback",
        "http://127.0.0.1:8080/oauth/idpcallback",
        "http://localhost:8085/oauth/idpcallback",
        "http://127.0.0.1:8085/oauth/idpcallback",
        "http://localhost:8086/oauth/idpcallback",
        "http://127.0.0.1:8086/oauth/idpcallback",
    }
    for base, path in redirect_bases:
        uri = base.rstrip("/") + path
        if uri not in existing_redirects and uri not in redirects:
            redirects.append(uri)
    redirect_lines = "\n".join(f"      - {json.dumps(uri)}" for uri in redirects)
    rendered = rendered.replace(REDIRECT_MARKER, redirect_lines)

    if not hasattr(os, "getuid") or not hasattr(os, "getgid"):
        raise SystemExit("Run configure-idp.py on a POSIX host so Dex can read the private config")
    write_env_values(ENV_FILE, {
        "DEX_ISSUER_URL": issuer_url,
        "DEX_UPSTREAM_REDIRECT_URI": redirect_uri,
        "DEX_UID": str(os.getuid()),
        "DEX_GID": str(os.getgid()),
    })

    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=OUTPUT.parent, delete=False
    ) as generated:
        generated.write(rendered)
        temporary_path = Path(generated.name)
    temporary_path.chmod(0o600)
    temporary_path.replace(OUTPUT)
    OUTPUT.chmod(0o600)
    print(f"Generated {OUTPUT.relative_to(DEMO_DIR)} for {provider}.")


if __name__ == "__main__":
    main()

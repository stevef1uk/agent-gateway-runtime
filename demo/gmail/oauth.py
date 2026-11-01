#!/usr/bin/env python3
"""Human-only Gmail authorization. Never run inside an agent sandbox."""
import argparse
import json
import os
from pathlib import Path

from google_auth_oauthlib.flow import InstalledAppFlow

from connector import SCOPES


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--client", type=Path, required=True, help="Google Desktop OAuth client JSON")
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "credentials/token.json")
    args = parser.parse_args()
    os.umask(0o077)
    flow = InstalledAppFlow.from_client_secrets_file(str(args.client), SCOPES, autogenerate_code_verifier=True)
    credentials = flow.run_local_server(host="127.0.0.1", port=0, access_type="offline",
                                        prompt="consent", authorization_prompt_message="Open this URL in your browser: {url}")
    granted = credentials.granted_scopes or credentials.scopes
    if not credentials.refresh_token or not set(SCOPES).issubset(set(granted or [])):
        raise SystemExit("Both Gmail read and send permissions and a refresh token are required. Reconnect.")
    data = json.loads(credentials.to_json())
    data["scopes"] = list(granted)
    args.output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = args.output.with_suffix(".tmp")
    # Atomic write with explicit permissions, including when replacing old files.
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(data, stream)
        os.replace(temporary, args.output)
    finally:
        temporary.unlink(missing_ok=True)
    print(f"Saved connector credentials to {args.output}. Do not give this file to the agent.")


if __name__ == "__main__":
    main()

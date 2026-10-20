#!/usr/bin/env python3
"""Point an OpenShell gateway.toml at the Agent Gateway egress proxy — idempotently.

What it does (all-or-nothing, writes nothing unless the result parses as TOML):
  - repairs duplicate `[openshell.drivers.*]` table headings (TOML rejects any
    duplicate within a namespace, so the gateway refuses to boot until fixed)
  - upserts the upstream-proxy stanza into the FIRST `[openshell.drivers.<DRIVER>]`
    block (or appends one when absent); other keys already in that block —
    e.g. `grpc_endpoint`, `supervisor_image`, `supervisor_bin` — are preserved
  - removes any duplicated driver table headings it finds, keeping the first
  - pins `[openshell.gateway] compute_driver` (schema v2) so the gateway does
    not silently fall back to the podman driver
  - validates the result with tomllib before writing, and chmod 600s the file

Usage:
  patch-driver-config.py --selftest                       # fixture tests, no writes
  patch-driver-config.py --check GATEWAY_TOML             # report only, no writes
  patch-driver-config.py GATEWAY_TOML PROXY_URL AUTH_FILE [docker|podman]

Exit codes: 0 ok, 1 check failed, 2 unreadable/unparseable/unfixable, 3 selftest
failures. Requires python3 >= 3.11 (tomllib).
"""

from __future__ import annotations

import os
import pathlib
import re
import sys
import tomllib

DEFAULT_DRIVER = "docker"

# Keys this tool owns inside the driver block. Everything else there — engine
# endpoint, supervisor paths, comments — belongs to the rest of the config and
# is never touched.
STANZA_KEYS: dict[str, str] = {
    "https_proxy": 'https_proxy = "{proxy}"',
    "proxy_auth_file": 'proxy_auth_file = "{auth}"',
    "proxy_auth_allow_insecure": "proxy_auth_allow_insecure = true",
    "proxy_connect_by_hostname": "proxy_connect_by_hostname = true",
}


def err(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)


def block_re(name: str) -> re.Pattern[str]:
    """Header + full body of `[openshell.drivers.<name>]`; trailing comment ok.

    The block ends at the next line-start `[` (any table heading) or EOF.
    """
    return re.compile(
        rf"(?ms)^\[openshell\.drivers\.{re.escape(name)}\][ \t]*(?:#.*)?\r?\n"
        rf".*?(?=^[ \t]*\[|\Z)"
    )


def driver_names(text: str) -> list[str]:
    """Every openshell.drivers.* table heading name present in the text."""
    return re.findall(r"^\[openshell\.drivers\.([A-Za-z0-9_-]+)\][ \t]*", text, re.M)


def dedupe_duplicates(text: str) -> tuple[str, list[str]]:
    """Remove every driver table block except the first of each name."""
    repaired: list[str] = []
    for name in sorted(set(driver_names(text))):
        spans = list(block_re(name).finditer(text))
        if len(spans) > 1:
            repaired.append(name)
        for m in sorted(spans[1:], key=lambda m: m.start(), reverse=True):
            text = text[: m.start()] + text[m.end() :]
    return text, repaired


def ensure_gateway_section(text: str, driver: str) -> str:
    """Upsert `[openshell.gateway] compute_driver` (schema v2 active driver)."""
    key = f'compute_driver = "{driver}"'
    section = re.compile(
        r"(?ms)^\[openshell\.gateway\][ \t]*(?:#.*)?\r?\n.*?(?=^[ \t]*\[|\Z)"
    )
    m = section.search(text)
    if m:
        body = m.group(0)
        if re.search(r"(?m)^compute_driver\s*=", body):
            body = re.sub(r"(?m)^compute_driver\s*=.*$", key, body, count=1)
        else:
            body = body.rstrip("\n") + "\n" + key + "\n"
        return text[: m.start()] + body + text[m.end() :]
    # No [openshell.gateway] yet: insert right after the `version` key of the
    # [openshell] table (guaranteed present by the schema-v2 preflight).
    ver = re.search(r"(?m)^version\s*=\s*\d+[^\n]*\n", text)
    if not ver:
        err("schema v2 marker 'version = 2' not found in gateway.toml")
        sys.exit(2)
    return text[: ver.end()] + f"\n[openshell.gateway]\n{key}\n" + text[ver.end() :]


def upsert_stanza(text: str, driver: str, proxy: str, auth_file: str) -> str:
    """Upsert the stanza keys into the first `[openshell.drivers.<driver>]` block."""
    vals = {"proxy": proxy, "auth": auth_file}
    entries: list[tuple[str, str]] = [
        ("https_proxy", STANZA_KEYS["https_proxy"].format(**vals)),
        ("proxy_auth_file", STANZA_KEYS["proxy_auth_file"].format(**vals)),
        ("proxy_auth_allow_insecure", STANZA_KEYS["proxy_auth_allow_insecure"]),
        ("proxy_connect_by_hostname", STANZA_KEYS["proxy_connect_by_hostname"]),
    ]
    m = block_re(driver).search(text)
    if not m:
        block = "\n".join(lit for _, lit in entries)
        return text.rstrip("\n") + f"\n\n[openshell.drivers.{driver}]\n{block}\n"
    body = m.group(0)
    hdr_end = body.index("\n")  # column right after the table heading line
    for key, lit in entries:
        if re.search(rf"(?m)^{key}\s*=", body):
            body = re.sub(rf"(?m)^{key}\s*=.*$", lit, body, count=1)
        else:
            body = body[: hdr_end + 1] + lit + "\n" + body[hdr_end + 1 :]
    return text[: m.start()] + body + text[m.end() :]


def load_prepared(path: pathlib.Path) -> tuple[str, list[str]]:
    """Read and auto-repair duplicate driver table headings when that is what broke it."""
    text = path.read_text()
    try:
        tomllib.loads(text)
        return text, []
    except tomllib.TOMLDecodeError as e:
        # TOML phrasings vary ("duplicate key", "Cannot declare ... twice");
        # trigger the repair whenever a driver heading appears more than once.
        dupes = sorted(
            n
            for n in set(driver_names(text))
            if len(re.findall(rf"^\[openshell\.drivers\.{re.escape(n)}\]", text, re.M))
            > 1
        )
        if not dupes:
            err(f"{path} does not parse as TOML: {e}")
            sys.exit(2)
        text, repaired = dedupe_duplicates(text)
        try:
            tomllib.loads(text)
        except tomllib.TOMLDecodeError as e2:
            err(f"{path} has duplicate tables that could not be safely deduped: {e2}")
            sys.exit(2)
        return text, repaired


def apply_patch(path: pathlib.Path, proxy: str, auth_file: str, driver: str) -> None:
    text, repaired = load_prepared(path)
    old = path.read_text()  # keep the on-disk original for a real no-op check
    text = ensure_gateway_section(text, driver)
    text = upsert_stanza(text, driver, proxy, auth_file)
    try:
        tomllib.loads(text)  # never write anything that does not parse
    except tomllib.TOMLDecodeError as e:
        err(f"patch would produce invalid TOML, not written: {e}")
        sys.exit(2)
    if text == old:
        print(f"already up to date: {path}")
        return
    if repaired:
        print(f"repaired duplicate driver table(s): {', '.join(repaired)}")
    path.write_text(text)
    path.chmod(0o600)


def report(path: pathlib.Path) -> int:
    text, repaired = load_prepared(path)
    if repaired:
        print(
            f"⚠ {path}: duplicate driver table(s) present (a patch run would repair): "
            + ", ".join(repaired)
        )
    names = sorted(set(driver_names(text)))
    gw = re.search(r'(?m)^compute_driver\s*=\s*"?([A-Za-z0-9_-]+)"?', text)
    print(f"driver tables present : {', '.join(names) if names else '(none)'}")
    print(
        f"active compute driver : {gw.group(1) if gw else '(unset — gateway default applies)'}"
    )
    for key in (
        "https_proxy",
        "proxy_auth_file",
        "proxy_auth_allow_insecure",
        "proxy_connect_by_hostname",
    ):
        m = re.search(rf"(?m)^{key}\s*=\s*(.*)$", text)
        print(f"{key + ':':26}{m.group(1) if m else '(missing)'}")
    missing = [k for k in STANZA_KEYS if not re.search(rf"(?m)^{k}\s*=", text)]
    if missing:
        print("✗ upstream proxy stanza missing key(s): " + ", ".join(missing))
        return 1
    print("✓ upstream proxy stanza present")
    return 0


def selftest() -> int:
    """Fixture tests covering the shapes that broke the Mac gateway."""
    ok = True

    def check(cond: bool, label: str) -> None:
        nonlocal ok
        print(f"  {'PASS' if cond else 'FAIL'}: {label}")
        ok = ok and cond

    import tempfile

    with tempfile.TemporaryDirectory() as td:
        tmp = pathlib.Path(td)

        # 1. The exact duplicate-table layout found on the Mac (gateway refused
        #    to boot: "duplicate key `docker` in table `openshell.drivers`").
        mac_broken = """\
[openshell]
version = 2

[openshell.drivers.podman]
allow_driver_config = true
https_proxy = "http://127.0.0.1:8088"
proxy_auth_file = "/Users/u/.config/openshell/upstream-proxy-auth"
proxy_auth_allow_insecure = true
proxy_connect_by_hostname = true

[openshell.drivers.docker]
https_proxy = "http://host.docker.internal:8088"
proxy_auth_file = "/Users/u/.config/openshell/upstream-proxy-auth"
proxy_auth_allow_insecure = true
proxy_connect_by_hostname = "true"

[openshell.drivers.docker]
https_proxy = "http://host.docker.internal:8088"
proxy_auth_file = "/Users/u/.config/openshell/upstream-proxy-auth"
proxy_auth_allow_insecure = true
proxy_connect_by_hostname = "true"
"""
        f = tmp / "mac-broken.toml"
        f.write_text(mac_broken)
        apply_patch(
            f,
            "http://host.docker.internal:8088",
            "/Users/u/.config/openshell/upstream-proxy-auth",
            "docker",
        )
        cfg = tomllib.loads(f.read_text())
        check(
            cfg["openshell"]["gateway"]["compute_driver"] == "docker",
            "mac-broken: compute_driver pinned to docker",
        )
        check(
            cfg["openshell"]["drivers"]["docker"]["proxy_connect_by_hostname"] is True,
            'mac-broken: proxy_connect_by_hostname is boolean true (was the string "true")',
        )
        check(
            cfg["openshell"]["drivers"]["podman"]["allow_driver_config"] is True,
            "mac-broken: podman block preserved",
        )
        check(
            f.read_text().count("[openshell.drivers.docker]") == 1,
            "mac-broken: single docker table heading",
        )
        check(os.stat(f).st_mode & 0o777 == 0o600, "mac-broken: file mode 600")
        check(
            "[openshell.gateway]\ncompute_driver" in f.read_text(),
            "mac-broken: gateway section inserted",
        )

        # 2. The verified Linux layout — patching must be a byte-for-byte no-op
        #    and must never drop engine keys or gateway TLS/JWT settings.
        linux = """\
[openshell]
version = 2

[openshell.gateway]
compute_driver = "docker"
guest_tls_ca = "/home/u/.config/openshell/tls/ca.crt"

disable_tls = false

[openshell.gateway.tls]
cert_path = "/home/u/.config/openshell/tls/server/tls.crt"
key_path = "/home/u/.config/openshell/tls/server/tls.key"
client_ca_path = "/home/u/.config/openshell/tls/ca.crt"

[openshell.gateway.gateway_jwt]
signing_key_path = "/home/u/.config/openshell/jwt/signing.pem"
public_key_path = "/home/u/.config/openshell/jwt/public.pem"
kid_path = "/home/u/.config/openshell/jwt/kid"
gateway_id = "local-gateway"
ttl_secs = 3600

[openshell.gateway.auth]
allow_unauthenticated_users = false

[openshell.drivers.docker]
grpc_endpoint = "https://127.0.0.1:17670"
supervisor_image = "ghcr.io/nvidia/openshell/supervisor:0.1.4"
supervisor_bin = "/home/u/.local/bin/openshell-sandbox"

# Upstream corporate proxy = the Agent Gateway egress proxy (demo stack).
# OpenShell chains policy-approved TLS CONNECT tunnels through it; the
# credential file below is rewritten per delegation run by the demo script.
https_proxy = "http://127.0.0.1:8088"
proxy_auth_file = "/home/u/.config/openshell/upstream-proxy-auth"
proxy_auth_allow_insecure = true
proxy_connect_by_hostname = true
"""
        f = tmp / "linux.toml"
        f.write_text(linux)
        apply_patch(
            f,
            "http://127.0.0.1:8088",
            "/home/u/.config/openshell/upstream-proxy-auth",
            "docker",
        )
        check(
            f.read_text() == linux,
            "linux: idempotent — already-correct config unchanged",
        )
        cfg = tomllib.loads(f.read_text())
        check(
            cfg["openshell"]["drivers"]["docker"]["grpc_endpoint"]
            == "https://127.0.0.1:17670",
            "linux: grpc_endpoint preserved",
        )
        check(
            cfg["openshell"]["gateway"]["guest_tls_ca"]
            == "/home/u/.config/openshell/tls/ca.crt",
            "linux: guest_tls_ca preserved",
        )

        # 3. Header with a trailing comment — the shape the old regex failed on.
        f = tmp / "trailing-comment.toml"
        f.write_text(
            "[openshell]\nversion = 2\n"
            '[openshell.gateway]\ncompute_driver = "docker"\n'
            "[openshell.drivers.docker] # the agent gateway egress proxy\n"
            'grpc_endpoint = "https://127.0.0.1:17670"\n'
        )
        apply_patch(f, "http://host.docker.internal:8088", "/Users/u/x", "docker")
        text = f.read_text()
        tomllib.loads(text)
        check(
            text.count("[openshell.drivers.docker]") == 1,
            "trailing-comment: header patched in place, no duplicate appended",
        )
        cfg = tomllib.loads(text)
        check(
            cfg["openshell"]["drivers"]["docker"]["https_proxy"]
            == "http://host.docker.internal:8088",
            "trailing-comment: stanza keys added to the commented header",
        )

        # 4. Fresh schema-v2 file with no driver block at all.
        fresh = (
            "[openshell]\nversion = 2\n\n[openshell.gateway.tls]\n"
            'cert_path = "/Users/u/.config/openshell/tls/server/tls.crt"\n'
        )
        f = tmp / "fresh.toml"
        f.write_text(fresh)
        apply_patch(f, "http://host.docker.internal:8088", "/Users/u/x", "docker")
        cfg = tomllib.loads(f.read_text())
        check(
            cfg["openshell"]["gateway"]["compute_driver"] == "docker",
            "fresh: compute_driver inserted",
        )
        check(
            cfg["openshell"]["drivers"]["docker"]["https_proxy"]
            == "http://host.docker.internal:8088",
            "fresh: stanza appended",
        )

        # 5. --check flags a missing stanza and never writes.
        f = tmp / "check-missing.toml"
        f.write_text(fresh)
        rc = report(f)
        check(
            rc == 1 and f.read_text() == fresh,
            "report(): missing stanza flagged, file untouched",
        )

    print("selftest: ALL PASS" if ok else "selftest: FAILURES")
    return 0 if ok else 1


def main(argv: list[str]) -> int:
    args = argv[1:]
    if args and args[0] == "--selftest":
        return selftest()
    if args and args[0] == "--check":
        target = pathlib.Path(args[1]) if len(args) > 1 else None
        if target is None or not target.is_file():
            err(
                f"{args[1] if len(args) > 1 else '(no path given)'}: gateway.toml not found"
            )
            return 2
        return report(target)
    if not args:
        print(__doc__)
        return 2
    if len(args) < 3:
        print(__doc__)
        return 2
    path, proxy, auth_file = pathlib.Path(args[0]), args[1], args[2]
    driver = args[3] if len(args) > 3 else DEFAULT_DRIVER
    if len(args) > 4 or driver not in ("docker", "podman"):
        err(f"unsupported driver '{driver}' (use docker or podman)")
        return 2
    if not path.is_file():
        err(f"{path}: not found — the gateway creates this file on first boot")
        return 2
    apply_patch(path, proxy, auth_file, driver)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

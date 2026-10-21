#!/bin/bash
# Register THIS machine's redirect URIs in demo/dex/config.yaml.
#
# Dex's OIDC client refuse a callback whose exact redirect_uri is not on the
# list ("Bad Request — Unregistered redirect_uri") — and the list is per-host
# by design. A clone of this repo on a new machine (a Mac in particular)
# therefore needs its own IP form registered the first time the console is
# opened via anything other than localhost.
#
# This script is idempotent: it appends the machine's LAN IPv4 addresses
# (localhost and 127.0.0.1 are always in the upstream file) to BOTH redirect
# lists (the staticClient and the mock connector), and reports whether dex
# needs recreating to re-read the file.
#
#   ./demo/refresh-dex-redirects.sh                        # compose file only
#   DEX_EXTRA_IPS="10.0.0.5 10.0.0.6" ./demo/refresh-dex-redirects.sh
#   DEX_CONSOLE_PORT=30083 ./demo/refresh-dex-redirects.sh # k3s NodePort form
#   ./demo/refresh-dex-redirects.sh --restart              # also recreate dex
#
# Nothing is removed: entries already present (other hosts' LAN URIs, etc.)
# are kept.
set -euo pipefail
# Docker or Podman — see lib/engine.sh (CONTAINER_ENGINE env override).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/engine.sh"


PORT="${DEX_CONSOLE_PORT:-8083}"
DO_RESTART=0
[ "${1:-}" = "--restart" ] && DO_RESTART=1

cd "$(dirname "$0")"
CFG="dex/config.yaml"
[ -f "$CFG" ] || { echo "no $CFG (run from the demo/ directory layout)" >&2; exit 1; }

# Collect this machine's LAN IPv4s (Mac: the airport/proto interfaces; Linux:
# everything global).
ips=""
if [ -n "${DEX_EXTRA_IPS:-}" ]; then ips="$DEX_EXTRA_IPS"; fi
if command -v hostname >/dev/null && [ "$(uname -s)" = "Linux" ]; then
  ips="$ips $(hostname -I 2>/dev/null || true)"
elif [ "$(uname -s)" = "Darwin" ]; then
  for i in en0 en1 en2 en3; do
    ip="$(ipconfig getifaddr "$i" 2>/dev/null || true)"
    [ -n "$ip" ] && ips="$ips $ip"
  done
fi
# Keep only usable LAN IPv4s: drop IPv6 (an http URI would need [brackets] and
# dex list entries stay simple) and the Docker-default 172.16/12 bridge space
# (those gateways route container egress, never a browser).
ips=$(printf '%s\n' $ips | python3 -c "
import sys, ipaddress
seen = set()
for tok in sys.stdin.read().split():
    try:
        a = ipaddress.ip_address(tok)
    except ValueError:
        continue
    if a.version != 4: continue
    if ipaddress.ip_address('172.16.0.0') <= a <= ipaddress.ip_address('172.31.255.255'): continue
    if tok in seen: continue
    seen.add(tok)
    print(tok)
")

python3 - "$CFG" "$PORT" $ips <<'PY'
import os, re, sys

cfg, port = sys.argv[1], sys.argv[2]
new_ips = sys.argv[3:]
text = open(cfg).read()
anchor_re = re.compile(r"^([ \t]*)- http://127\.0\.0\.1:%s/oidc/callback$" % re.escape(port), re.M)
added = []
matches = list(anchor_re.finditer(text))
if not matches:
    sys.exit("no `- http://127.0.0.1:%s/oidc/callback` anchors found in %s" % (port, cfg))
# insert after the last anchor in each list block (dedent-aware: anchors with
# different indents are different lists)
seen_indents = set()
out = []
for line in text.splitlines(keepends=True):
    m = anchor_re.match(line)
    if m and m.group(1) not in seen_indents:
        seen_indents.add(m.group(1))
        out.append(line)
        for ip in new_ips:
            uri = "http://%s:%s/oidc/callback" % (ip, port)
            # this list's membership only: dex validates the redirect at BOTH
            # the staticClient and the connector list, so "uri anywhere in the
            # file" would silently leave a half-registered (and failing) state
            list_re = re.compile(
                r"^%s- http://%s:%s/oidc/callback$" % (re.escape(m.group(1)), re.escape(ip), re.escape(port)), re.M)
            if not list_re.search(text):
                out.append("%s- %s\n" % (m.group(1), uri))
                added.append(uri)
    else:
        out.append(line)
open(cfg, "w").writelines(out)
for uri in added:
    print("added redirect:", uri)
sys.exit(2 if added else 0)
PY

changed=$?
if [ "$changed" = "2" ] || [ "$DO_RESTART" = "1" ]; then
  if command -v docker >/dev/null; then
    if compose version >/dev/null 2>&1; then COMPOSE=(compose); else COMPOSE=(docker-compose); fi
  else
    COMPOSE=(docker-compose)
  fi
  echo "recreating dex to re-read $CFG …"
  compose -f docker-compose.yml up -d --force-recreate dex >/dev/null
fi
exit 0

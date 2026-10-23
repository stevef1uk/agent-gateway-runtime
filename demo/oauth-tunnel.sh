#!/usr/bin/env bash
# ============================================================================
# MCP One Ring — expose the demo stack's OAuth gateway for claude.ai
# (a cloudflared quick-tunnel gives the OAuth layer a publicly reachable
# HTTPS issuer, so claude.ai's custom remote connector can complete the
# flow from Anthropic's side of the wire).
#
#   - starts cloudflared (quick tunnel — free, no account)
#   - derives https://<random>.trycloudflare.com
#   - inserts the OAuth callback into BOTH Dex redirect lists (idempotent,
#     keyed on the exact tunnel URL — a NEW tunnel URL means NEW entries)
#   - writes OAUTH_PUBLIC_BASE into demo/.env so compose picks it up
#   - recreates dex + gateway-mcp and sanity-checks discovery
#
# Requirements: cloudflared (single binary from
# github.com/cloudflare/cloudflared/releases), the stack's other services
# up (docker compose up -d once).
#
# Usage:  ./oauth-tunnel.sh                 # start + wire + report
#         ./oauth-tunnel.sh --kill          # stop tunnel + revert .env
#         CLOUDFLARED=/path/to/cloudflared ./oauth-tunnel.sh
#
# NOTE: quick tunnels renumber whenever cloudflared dies; connectors pinned
# to a dead URL must be re-added after a rerun (a named tunnel / own domain
# is the stable answer — Phase 4).
# ============================================================================
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DEMO_DIR"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/engine.sh"

GW_PORT=${GATEWAY_MCP_HOST_PORT:-8085}
GW=http://localhost:$GW_PORT
CFG="dex/config.yaml"
ENVF=".env"
LOG="${TEMP:-/tmp}/opencode/cloudflared.log"
PIDF="${TEMP:-/tmp}/opencode/cloudflared.pid"
CLOUDFLARED=${CLOUDFLARED:-cloudflared}

if [ "${1:-}" = "--kill" ]; then
  [ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF"
  if [ -f "$ENVF" ]; then
    python3 - "$ENVF" <<'PY'
import sys
path = sys.argv[1]
keep = [l for l in open(path).read().splitlines() if not l.startswith("OAUTH_PUBLIC_BASE=")]
open(path, "w").write("\n".join(keep) + ("\n" if keep else ""))
PY
  fi
  echo "tunnel stopped; OAUTH_PUBLIC_BASE reverted to the compose default"
  exit 0
fi

step() { printf "\n\033[1;36m%s\033[0m\n" "== $1"; }
okk()  { printf "  \033[0;32m✓ %s\033[0m\n" "$*"; }
bad()  { printf "  \033[0;31m✗ %s\033[0m\n" "$*"; }

command -v "$CLOUDFLARED" >/dev/null || { bad "cloudflared not on PATH (see the header)"; exit 1; }

step "Stack sanity"
curl -fsS -o /dev/null "http://localhost:5556/dex/healthz" || { bad "dex not healthy (docker compose up -d first)"; exit 1; }
curl -fsS -o /dev/null "$GW/healthz" || { bad "gateway-mcp not healthy"; exit 1; }
okk "dex + gateway-mcp reachable"

step "HTTPS tunnel (cloudflared quick)"
[ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null; rm -f "$PIDF"
: > "$LOG"
"$CLOUDFLARED" tunnel --url "http://localhost:$GW_PORT" --no-autoupdate >"$LOG" 2>&1 &
echo $! > "$PIDF"
URL=""
for _ in $(seq 1 30); do
  URL=$(grep -a -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOG" | head -1 || true)
  [ -n "$URL" ] && break
  sleep 1
done
if [ -z "$URL" ]; then bad "no tunnel URL in cloudflared output (see $LOG)"; exit 1; fi
okk "tunnel: $URL"

step "Dex redirect URIs + compose env"
CALLBACK="$URL/oauth/idpcallback"
python3 - "$CFG" "$CALLBACK" <<'PY'
import re, sys
cfg, cb = sys.argv[1], sys.argv[2]
text = open(cfg).read()
if cb in text:
    print("  ✓ redirect already registered")
    sys.exit(0)
out, done = [], set()
for line in text.splitlines(True):
    m1 = re.match(r"^([ \t]+)- http://127\.0\.0\.1:8083/oidc/callback$", line.rstrip("\n"))
    if m1 and m1.group(1) not in done:
        done.add(m1.group(1))
        out.append(line); out.append(f"{m1.group(1)}- {cb}\n")
        continue
    m2 = re.match(r"^([ \t]+)- \$DEX_MOCK_REDIRECT_URIS$", line.rstrip("\n"))
    if m2 and m2.group(1) not in done:
        done.add(m2.group(1))
        out.append(f"{m2.group(1)}- {cb}\n"); out.append(line)
        continue
    out.append(line)
open(cfg, "w").write("".join(out))
print("  ✓ callback inserted:", cb)
PY

grep -a -q "OAUTH_PUBLIC_BASE=" "$ENVF" 2>/dev/null && \
  sed -i "s|^OAUTH_PUBLIC_BASE=.*|OAUTH_PUBLIC_BASE=$URL|" "$ENVF" || \
  printf '\nOAUTH_PUBLIC_BASE=%s\n' "$URL" >> "$ENVF"
okk ".env: OAUTH_PUBLIC_BASE=$URL"

step "Recreate dex + gateway-mcp"
compose up -d --force-recreate dex gateway-mcp >/dev/null
sleep 6

step "Discovery through the tunnel"
ISSUER=$(curl -fsS "http://localhost:$GW_PORT/.well-known/oauth-authorization-server" | python3 -c 'import sys,json; print(json.load(sys.stdin)["issuer"])')
if [ "$ISSUER" = "$URL" ]; then okk "issuer advertised externally: $ISSUER"; else bad "issuer mismatch: $ISSUER"; fi
if curl -fsS -o /dev/null "$URL/healthz"; then okk "public endpoint reachable (from this host)"; else bad "public endpoint unreachable"; fi

cat <<EOF

Now, in claude.ai:
  1. Settings → Connectors → Add custom connector
  2. URL: $URL/mcp
  3. Follow the OAuth popup (Dex mock: one click)
  4. CRM tools render — every call enforced + audited per tool.

(The quick tunnel renumbers when cloudflared restarts; rerun this script
and re-add the connector with the new URL in that case.)
EOF

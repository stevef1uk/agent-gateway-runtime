# Local personal agents (OpenClaw, Hermes, your own runtime)

*"I installed a personal agent on my laptop — how does Agent Gateway fit?"*

The exact anxiety personal-agent users have is the one Agent Gateway answers.
A local assistant that runs 24/7, holds your credentials and can text, browse
and buy things is powerful *and* unsettling: **what did it actually do this
week? what can it do? how do I stop it?** — *right now, not tomorrow*.

Agent Gateway gives a household/`homelab` deployment of a personal agent the
same spine enterprises want:

- **One per-skill delegation** instead of "the agent has my keys" — the
  assistant holds a scoped, capped, revocable grant
- **Human approval for the risky bit** — over cap → the action *parks* and
  waits for you
- **One audit trail** — every allow/hold/deny with reason, exportable
- **Instant revoke** — from the console (your phone's browser works)

## Fifteen-minute personal setup

```bash
# 1) run the stack on the laptop / NAS / small VPS
git clone <this repository> agent-gateway-demo && cd agent-gateway-demo/demo
docker compose up -d

# 2) open the console and sign in (SSO via the bundled Dex, or your own IdP)
open http://localhost:8083

# 3) create a delegation for the agent
#    agent_id: laptop-openclaw • resources: /orders, /home-commands •
#    actions: read, create • cap: €200 per order • TTL: your choice
#    → the console shows the one-time agent secret; copy it

# 4) give the runtime its credential (env file, secret store, config)
export AGENT_GATEWAY_URL=http://localhost:8080
export AGENT_DELEGATION_ID=del-…          # step 3
export AGENT_DELEGATION_SECRET=…          # step 3 (43 chars, one-time read)
```

## Wiring it into the runtime

Personal-agent runtimes differ in what they let you configure. Three shapes,
in increasing integration depth:

### Shape 1 — MCP-registered runtimes (OpenClaw class)

OpenClaw keeps an **outbound MCP server registry** (`openclaw mcp add`) and
projects configured servers into its agent runtimes; community builds
commonly run isolated, credential-light MCP sidecars per capability. The
gateway slot is the same shape: register a tiny **gateway MCP adapter** as
the "skill server"; every tool call it receives is relayed through the
gateway, so enforcement, spend caps, approvals and audit happen outside the
agent no matter which skill the model chose.

The adapter is deliberately small (~40 lines, stdio server):

```python
#!/usr/bin/env python3
"""agent-gateway MCP adapter — relays OpenClaw skill calls through the PEP.
Env: AGENT_GATEWAY_URL, AGENT_DELEGATION_ID, AGENT_DELEGATION_SECRET
Each MCP tool maps to (resource, action) for the gateway's decision call."""
import json, os, sys, urllib.request

GW    = os.environ["AGENT_GATEWAY_URL"]
DEL   = os.environ["AGENT_DELEGATION_ID"]
SEC   = os.environ["AGENT_DELEGATION_SECRET"]
TOOLS = {  # tool name -> (resource, action, http path)
  "orders_create": ("/orders", "create", "/orders"),
}

def token():
    body = json.dumps({"delegation_id": DEL, "ttl_seconds": 300,
                       "agent_secret": SEC}).encode()
    req = urllib.request.Request(GW + "/token", data=body,
            headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req))["access_token"]

def call(tool, payload):
    resource, action, path = TOOLS.get(tool, (tool, "execute", "/" + tool))
    body = json.dumps({"data": payload}).encode()
    req = urllib.request.Request(GW + path, data=body,
            headers={"Content-Type": "application/json",
                     "Authorization": "Bearer " + token()})
    try:
        r = urllib.request.urlopen(req)
        return {"status": r.status, "result": r.read().decode()[:2000]}
    except urllib.error.HTTPError as e:
        if e.code == 202:                       # over the cap: held!
            a = json.load(e)
            return {"status": "held_for_approval", "approval_id": a.get("approval_id"),
                    "note": "ask the human to open the gateway console"}
        return {"status": e.code, "error": e.read().decode()[:500]}

for line in sys.stdin:                          # minimal JSONL/MCP shim
    if not line.strip(): continue
    if '"method":"initialize"' in line:
        print(json.dumps({"jsonrpc":"2.0","id":json.loads(line)["id"],
            "result":{"protocolVersion":"2024-11-05",
                      "serverInfo":{"name":"agent-gateway","version":"0.1"},
                      "capabilities":{"tools":{}}}}), flush=True); continue
    if '"tools/list"' in line:
        print(json.dumps({"jsonrpc":"2.0","id":json.loads(line)["id"],
            "result":{"tools":[{"name":t,"inputSchema":{"type":"object"}}
                               for t in TOOLS]}}), flush=True); continue
    try:
        req = json.loads(line)
        name = (req.get("params") or {}).get("name")
        args = (req.get("params") or {}).get("arguments") or {}
        print(json.dumps({"jsonrpc":"2.0","id":req.get("id"),
            "result":{"content":[{"type":"text","text":json.dumps(call(name,args))}]}}),
            flush=True)
    except Exception as e:
        print(json.dumps({"error": str(e)}), flush=True)
```

Register it with the runtime (OpenClaw example):

```bash
openclaw mcp add agent-gateway -- command python3 /path/to/adapter.py
openclaw mcp probe agent-gateway     # lists the tools it exposes
```

Now the model calling `orders_create` goes: **OpenClaw skill layer → adapter →
gateway PEP → (allow | hold-for-approval | deny) → audited**. And because the
gateway does the governing, OpenClaw's own `tools.allow/deny` per-agent config
stays as the *convenience* surface: it shapes what the model even sees, while
the gateway guarantees what the human approved. Belt and braces.

### Shape 2 — HTTP tool agents

Any runtime that takes a base URL for a tool (CrewAI, LangChain tools,
Hermes-style runners, plain `requests` in your own script): swap the URL to
the gateway and hand the agent the token — the
[one-line configuration change](Integration-Patterns.md). Tool derivation is
from plain HTTP (`/path` = resource, verb = action), with `X-Agent-*` headers
as optional overrides.

### Shape 2½ — the whole runtime behind the gateway (OpenClaw via OpenShell, proxy mode)

The newest wiring treats the *agent itself* as the governed party: the
gateway runs an **egress forward proxy** (`GATEWAY_PROXY_ADDR=:8088`) and
the agent — typically an **OpenClaw** persona running inside an
[NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) sandbox — routes
*its entire outbound traffic* through it. Every destination becomes one
authorization decision:

| What OpenClaw does | What the gateway does |
|---|---|
| calls `https://api.github.com/…` | `read` on `api.github.com` → allow or **202 held for you** (per the delegation's approval rule) |
| POSTs anywhere | method maps to an action — `create`/`update`/`delete` — held on the `*` rule |
| `npm install` a fresh dependency | registry hosts are allowlisted per delegation; everything else is a flat **403 policy_denied**, no human needed |
| revocation night | delegation revoked → the very next call is **403**, even with a valid token |

The sandbox never sees your model keys (OpenShell's `inference.local`
routing keeps provider credentials outside) and never gets a way around
the gateway (OpenShell's default-deny policy allowlists exactly one
egress target — the proxy). The same audit lines record
`openclaw-agent-1 / alice / destination / why permitted` for every call.

* Wiring and low-level setup:
  [OpenShell-Integration.md](https://github.com/stevef/agent-gateway/blob/main/OpenShell-Integration.md)
  (main repo) — including the Linux/Mac platform notes.
* Call-by-call scripted walkthrough: **Demo 5** (`demo/egress-demo.sh`,
  see [Demos.md](Demos.md)).
* k3s deployments surface the proxy on NodePort `30088` — cluster
  OpenShell gateways point their upstream at `http://<node>:30088`
  ([k3s/README.md](../k3s/README.md)).

### Shape 3 — already-filed skills that call third-party SaaS

If the skill talks to a *SaaS API* (mail, calendar, GitHub): register that
provider's API base as the gateway `UPSTREAM_URL` per delegation, keep the
provider credential **with the gateway** instead of inside the agent
environment. The agent never sees the long-lived secret; the request is
contextualised per delegation and fully audited.

## What the household story looks like afterwards

| Moment | Without the gateway | With it |
|---|---|---|
| "Do X for me" | model asks: yes/no — you hope | capped, scoped — the *risky* path parks at 202 for you to approve |
| Wrong turn overnight | you find receipts later | revoke it in one click; blast radius = TTL minutes |
| "What did it do?" | scroll chat history | one audit trail with reasons, exported to CSV/JSON |

## Honest current limits (so nothing over-promises)

- **Shell/desktop tools** — a skill that executes `commands`/`curl` in the
  OS historically bypassed the HTTP gateway. That is exactly what **Shape 2½**
  solves: the entire runtime is put behind the egress proxy (OpenShell +
  OpenClaw), so even OS-level outbound calls are governed. What remains
  ungoverned today is a host you deliberately run *outside* an OpenShell
  sandbox with root access to the network stack.
- **MCP-native flows** — today you register the *adapter*, not the gateway
  itself, as an MCP server; a native gateway MCP servership (per-tool
  JSON-RPC parsing) is the planned default.
- **One household, one deployment** — the compose stack suits a personal
  level of traffic; scale paths are in the
  [Deployment Guide](Deployment-Guide.md) when it becomes a small business.

Free tier: yes — a licence token by email
([Pricing](Pricing.md)) before you go past the demo key pair.

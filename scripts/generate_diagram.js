const fs = require('fs');
const path = require('path');
const { chromium } = require('/home/stevef/dev/artificial_mind/node_modules/playwright-core');

const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: #0a0f1d;
    color: #f1f5f9;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    width: 2200px;
    height: 1350px;
    padding: 40px 50px;
    display: flex;
    flex-direction: column;
    overflow: hidden;
    position: relative;
  }

  /* Grid background effect */
  body::before {
    content: "";
    position: absolute;
    top: 0; left: 0; right: 0; bottom: 0;
    background-image: 
      linear-gradient(to right, rgba(255,255,255,0.03) 1px, transparent 1px),
      linear-gradient(to bottom, rgba(255,255,255,0.03) 1px, transparent 1px);
    background-size: 40px 40px;
    pointer-events: none;
  }

  /* Top Header */
  header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    border-bottom: 1px solid rgba(255,255,255,0.1);
    padding-bottom: 24px;
    margin-bottom: 30px;
    position: relative;
    z-index: 2;
  }
  .title-group h1 {
    font-size: 34px;
    font-weight: 800;
    letter-spacing: -0.02em;
    background: linear-gradient(135deg, #ffffff 30%, #94a3b8 100%);
    -webkit-background-clip: text;
    -webkit-text-fill-color: transparent;
    display: flex;
    align-items: center;
    gap: 16px;
  }
  .logo-badge {
    background: linear-gradient(135deg, #3b82f6, #06b6d4);
    color: white;
    font-size: 16px;
    font-weight: 700;
    padding: 6px 14px;
    border-radius: 8px;
    letter-spacing: 0.05em;
    -webkit-text-fill-color: initial;
    box-shadow: 0 0 20px rgba(59, 130, 246, 0.4);
  }
  .title-group p {
    color: #94a3b8;
    font-size: 16px;
    margin-top: 6px;
    font-weight: 400;
  }
  .header-badges {
    display: flex;
    gap: 12px;
  }
  .h-badge {
    background: rgba(255,255,255,0.05);
    border: 1px solid rgba(255,255,255,0.12);
    padding: 8px 16px;
    border-radius: 20px;
    font-size: 13px;
    color: #cbd5e1;
    font-weight: 500;
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .h-badge .dot { width: 8px; height: 8px; border-radius: 50%; }
  .dot.blue { background: #38bdf8; box-shadow: 0 0 8px #38bdf8; }
  .dot.green { background: #34d399; box-shadow: 0 0 8px #34d399; }
  .dot.amber { background: #fbbf24; box-shadow: 0 0 8px #fbbf24; }

  /* Main Grid */
  .grid-container {
    display: grid;
    grid-template-columns: 340px 1fr 400px;
    gap: 30px;
    flex: 1;
    position: relative;
    z-index: 2;
  }

  /* Cards & Sections */
  .panel-title {
    font-size: 15px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    color: #64748b;
    margin-bottom: 20px;
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .panel-title span { color: #f8fafc; }

  /* Left Column: Principals */
  .col-left { display: flex; flex-direction: column; gap: 24px; }
  .actor-box {
    background: rgba(30, 41, 59, 0.7);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 14px;
    padding: 20px;
    position: relative;
  }
  .actor-box.human { border-left: 4px solid #38bdf8; }
  .actor-box.agent { border-left: 4px solid #a855f7; }
  .actor-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 12px;
  }
  .actor-title {
    font-size: 18px;
    font-weight: 700;
    color: #f8fafc;
    display: flex;
    align-items: center;
    gap: 10px;
  }
  .pill-tag {
    font-size: 11px;
    font-weight: 600;
    padding: 3px 8px;
    border-radius: 6px;
    text-transform: uppercase;
  }
  .pill-tag.blue { background: rgba(56, 189, 248, 0.15); color: #38bdf8; border: 1px solid rgba(56, 189, 248, 0.3); }
  .pill-tag.purple { background: rgba(168, 85, 247, 0.15); color: #c084fc; border: 1px solid rgba(168, 85, 247, 0.3); }
  .actor-desc {
    font-size: 13.5px;
    color: #94a3b8;
    line-height: 1.5;
    margin-bottom: 14px;
  }
  .actor-items {
    display: flex;
    flex-direction: column;
    gap: 8px;
  }
  .actor-item {
    background: rgba(15, 23, 42, 0.6);
    border: 1px solid rgba(255, 255, 255, 0.06);
    padding: 9px 12px;
    border-radius: 8px;
    font-size: 13px;
    color: #cbd5e1;
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  /* Center Column: Core AGW Platform */
  .col-center {
    display: flex;
    flex-direction: column;
    gap: 22px;
  }

  /* Top Box: Web Admin Console */
  .console-box {
    background: linear-gradient(180deg, rgba(30, 41, 59, 0.85) 0%, rgba(15, 23, 42, 0.95) 100%);
    border: 1px solid rgba(99, 102, 241, 0.35);
    border-radius: 16px;
    padding: 22px 26px;
    position: relative;
    box-shadow: 0 10px 30px rgba(99, 102, 241, 0.12);
  }
  .console-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 16px;
  }
  .console-title {
    font-size: 19px;
    font-weight: 700;
    color: #e0e7ff;
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .console-title .tag {
    background: rgba(99, 102, 241, 0.2);
    border: 1px solid #6366f1;
    color: #c7d2fe;
    font-size: 12px;
    padding: 2px 10px;
    border-radius: 999px;
    font-weight: 600;
  }
  .console-features-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 12px;
  }
  .cf-card {
    background: rgba(15, 23, 42, 0.85);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 10px;
    padding: 12px 14px;
  }
  .cf-card b {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 13.5px;
    color: #f8fafc;
    margin-bottom: 4px;
  }
  .cf-card p {
    font-size: 12px;
    color: #94a3b8;
    line-height: 1.4;
  }

  /* Center Bottom: Policy Enforcement & Core Stack */
  .pep-box {
    background: linear-gradient(180deg, rgba(30, 41, 59, 0.9) 0%, rgba(15, 23, 42, 0.98) 100%);
    border: 1px solid rgba(16, 185, 129, 0.35);
    border-radius: 16px;
    padding: 24px;
    flex: 1;
    display: flex;
    flex-direction: column;
    box-shadow: 0 10px 30px rgba(16, 185, 129, 0.1);
  }
  .pep-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 18px;
  }
  .pep-title {
    font-size: 19px;
    font-weight: 700;
    color: #d1fae5;
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .pep-title .tag {
    background: rgba(16, 185, 129, 0.2);
    border: 1px solid #10b981;
    color: #6ee7b7;
    font-size: 12px;
    padding: 2px 10px;
    border-radius: 999px;
    font-weight: 600;
  }

  .engine-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 14px;
    margin-bottom: 20px;
  }
  .engine-card {
    background: rgba(15, 23, 42, 0.7);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 12px;
    padding: 16px;
  }
  .engine-card h4 {
    font-size: 14.5px;
    font-weight: 700;
    color: #f1f5f9;
    margin-bottom: 8px;
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .engine-card ul {
    list-style: none;
    font-size: 12.5px;
    color: #94a3b8;
    display: flex;
    flex-direction: column;
    gap: 6px;
  }
  .engine-card ul li::before {
    content: "•";
    color: #38bdf8;
    font-weight: bold;
    display: inline-block;
    width: 1em;
  }

  .pep-bottom-row {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 14px;
    margin-top: auto;
  }
  .pep-subbox {
    background: rgba(15, 23, 42, 0.9);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: 10px;
    padding: 14px 16px;
  }
  .pep-subbox h5 {
    font-size: 13px;
    font-weight: 700;
    color: #cbd5e1;
    margin-bottom: 6px;
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .pep-subbox p {
    font-size: 12px;
    color: #94a3b8;
    line-height: 1.4;
  }

  /* Right Column: Protected Upstreams */
  .col-right {
    display: flex;
    flex-direction: column;
    gap: 18px;
  }
  .target-box {
    background: rgba(30, 41, 59, 0.7);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: 14px;
    padding: 18px 20px;
    border-right: 4px solid #10b981;
  }
  .target-box.api { border-right-color: #38bdf8; }
  .target-box.mcp { border-right-color: #ec4899; }
  .target-box.demo { border-right-color: #64748b; }

  .target-title {
    font-size: 17px;
    font-weight: 700;
    color: #f8fafc;
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 8px;
  }
  .target-desc {
    font-size: 12.5px;
    color: #94a3b8;
    line-height: 1.45;
    margin-bottom: 12px;
  }
  .target-examples {
    display: flex;
    flex-wrap: wrap;
    gap: 6px;
  }
  .target-pill {
    background: rgba(15, 23, 42, 0.7);
    border: 1px solid rgba(255, 255, 255, 0.1);
    color: #cbd5e1;
    font-size: 11.5px;
    padding: 4px 10px;
    border-radius: 6px;
    font-family: monospace;
  }

  /* Flow Connectors / Indicators */
  .flow-banner {
    background: linear-gradient(90deg, rgba(56,189,248,0.1), rgba(168,85,247,0.1), rgba(16,185,129,0.1));
    border: 1px solid rgba(255,255,255,0.08);
    border-radius: 12px;
    padding: 12px 20px;
    display: flex;
    justify-content: space-around;
    align-items: center;
    margin-top: 24px;
    font-size: 13px;
    color: #94a3b8;
    position: relative;
    z-index: 2;
  }
  .flow-step {
    display: flex;
    align-items: center;
    gap: 8px;
    font-weight: 600;
  }
  .flow-step.s1 { color: #38bdf8; }
  .flow-step.s2 { color: #c084fc; }
  .flow-step.s3 { color: #f59e0b; }
  .flow-step.s4 { color: #34d399; }
  .flow-arrow { color: #475569; font-size: 16px; }

</style>
</head>
<body>

  <!-- Header -->
  <header>
    <div class="title-group">
      <h1>
        <span class="logo-badge">AGENT GATEWAY</span>
        Conceptual Architecture &amp; Governance Platform
      </h1>
      <p>Decoupled Workload Identity, Delegated Least-Privilege Guardrails, and Human-in-the-Loop Policy Enforcement for AI Agents</p>
    </div>
    <div class="header-badges">
      <div class="h-badge"><span class="dot blue"></span> Cryptographic Delegation</div>
      <div class="h-badge"><span class="dot amber"></span> Human-in-the-Loop Approvals</div>
      <div class="h-badge"><span class="dot green"></span> Zero-Code API / MCP Onboarding</div>
    </div>
  </header>

  <!-- Main Grid -->
  <div class="grid-container">

    <!-- Column 1: Principals (Left) -->
    <div class="col-left">
      <div class="panel-title"><span>01</span> Principals &amp; Clients</div>

      <!-- Human Principal -->
      <div class="actor-box human">
        <div class="actor-header">
          <div class="actor-title">👤 Human Operator</div>
          <span class="pill-tag blue">Identity</span>
        </div>
        <div class="actor-desc">
          Signs in via Enterprise SSO. Grants time-bounded delegation authority with strict budget caps and risk rules.
        </div>
        <div class="actor-items">
          <div class="actor-item">
            <span>Identity Provider</span>
            <code>Google / Okta / Entra / Dex</code>
          </div>
          <div class="actor-item">
            <span>Protocol</span>
            <code>OIDC / PKCE Web Sessions</code>
          </div>
          <div class="actor-item">
            <span>Approval Actions</span>
            <code>Telegram / Web Console</code>
          </div>
        </div>
      </div>

      <!-- AI Agent Principal -->
      <div class="actor-box agent">
        <div class="actor-header">
          <div class="actor-title">🤖 AI Agent / Runtime</div>
          <span class="pill-tag purple">Workload</span>
        </div>
        <div class="actor-desc">
          Autonomous AI agents interact with tools on human behalf. Authenticate with distinct workload credentials; never receive raw API keys.
        </div>
        <div class="actor-items">
          <div class="actor-item">
            <span>Agent Frameworks</span>
            <code>Claude / Cursor / LangGraph</code>
          </div>
          <div class="actor-item">
            <span>Workload Identity</span>
            <code>SPIFFE / Agent Secret / JWT</code>
          </div>
          <div class="actor-item">
            <span>Client Protocols</span>
            <code>MCP JSON-RPC / REST Bearer</code>
          </div>
        </div>
      </div>

      <!-- Security Principles Callout -->
      <div class="actor-box" style="border-left: 4px solid #10b981;">
        <div class="actor-header">
          <div class="actor-title" style="font-size:15px;">🛡️ Zero-Trust Design</div>
        </div>
        <div class="actor-desc" style="font-size:12px; margin-bottom:0;">
          • No shared credentials between agent &amp; human<br>
          • Per-call cryptographic authorization<br>
          • Short-lived scoped JWTs (15m default)<br>
          • Instant token revocation via Redis
        </div>
      </div>
    </div>

    <!-- Column 2: AGW Platform & Admin Console (Center) -->
    <div class="col-center">
      <div class="panel-title"><span>02</span> Agent Gateway Control Plane &amp; Policy Enforcement (PEP / PDP)</div>

      <!-- Top: Admin Web Console Capabilities -->
      <div class="console-box">
        <div class="console-header">
          <div class="console-title">
            🖥️ Admin Web Console &amp; AI Assist
            <span class="tag">Zero-Code Management</span>
          </div>
          <div style="font-size:12px; color:#a5b4fc;">Live Web UI at <code>https://&lt;tenant&gt;.preprod.agw.sjfisher.com</code></div>
        </div>
        <div class="console-features-grid">
          <div class="cf-card">
            <b>🧙 5-Step Onboarding Wizard</b>
            <p>1-click provision dedicated PEP gateways for any REST API or MCP server with automatic Ingress routing.</p>
          </div>
          <div class="cf-card">
            <b>✨ Freeride AI Assistant</b>
            <p>Describe your needs in plain English; AI drafts upstream targets, action scopes, spend caps, and approvals.</p>
          </div>
          <div class="cf-card">
            <b>🔑 Live Endpoint Tester</b>
            <p>Mint fresh test JWTs in 1 click, customize GET/POST search params &amp; headers, and test live in browser.</p>
          </div>
          <div class="cf-card">
            <b>⚡ OPA Policy Playground</b>
            <p>Test Rego rules in real time. Hot-reloads live policy in ~5 seconds with instant syntax validation.</p>
          </div>
          <div class="cf-card">
            <b>🔒 2-Way Tap Approvals</b>
            <p>Manage held calls (HTTP 202). Approve or deny single-use requests via Web console or Telegram cards.</p>
          </div>
          <div class="cf-card">
            <b>📊 Audit &amp; Decision Explorer</b>
            <p>Full tamper-evident compliance log of every ALLOW, DENY, and HELD decision with filters and latency metrics.</p>
          </div>
        </div>
      </div>

      <!-- Bottom: Core Policy Enforcement Gateway -->
      <div class="pep-box">
        <div class="pep-header">
          <div class="pep-title">
            🛡️ Core Policy Enforcement Point (PEP) &amp; Decision Point (PDP)
            <span class="tag">In-Line Proxy Gate</span>
          </div>
          <div style="font-size:12px; color:#6ee7b7;">High-Performance Go Runtime</div>
        </div>

        <div class="engine-grid">
          <!-- Token Service -->
          <div class="engine-card">
            <h4>🎟️ Token Service (:8082)</h4>
            <ul>
              <li>RFC 8693 Token Exchange</li>
              <li>Agent Secret Verification</li>
              <li>Short-lived, audience-scoped JWTs</li>
              <li>Cryptographic key signing</li>
            </ul>
          </div>

          <!-- Authz PDP -->
          <div class="engine-card">
            <h4>⚖️ Authz Engine PDP (:8081)</h4>
            <ul>
              <li>Open Policy Agent (OPA) embedded</li>
              <li>Delegation scope &amp; action matching</li>
              <li>Spend cap limits calculation</li>
              <li>Single-use approval ticket minting</li>
            </ul>
          </div>

          <!-- Gateway PEP -->
          <div class="engine-card">
            <h4>🚪 Gateway PEP (:8080)</h4>
            <ul>
              <li>Reverse proxy for /mcp &amp; /api-*</li>
              <li>Intercepts every inbound call</li>
              <li>Holds risky calls (HTTP 202)</li>
              <li>Injects identity audit headers</li>
            </ul>
          </div>
        </div>

        <!-- Lower Sub-Row: State & Approvals -->
        <div class="pep-bottom-row">
          <div class="pep-subbox">
            <h5>💾 Distributed Storage &amp; Compliance Trail</h5>
            <p><b>PostgreSQL</b> stores permanent delegation contracts, approval audit logs, and transaction history. <b>Redis</b> powers sub-millisecond decision caching, instant JTI token revocation, and rate limiting.</p>
          </div>
          <div class="pep-subbox">
            <h5>📲 Telegram &amp; Web Tap-to-Approve</h5>
            <p>When an agent calls a high-risk action (e.g. <code>delete_customer</code>, refunds &gt; €50), the call is held while a cryptographic approval card is dispatched to Telegram and the Admin Web Console.</p>
          </div>
        </div>
      </div>

    </div>

    <!-- Column 3: Downstream Protected Targets (Right) -->
    <div class="col-right">
      <div class="panel-title"><span>03</span> Protected Upstream Targets</div>

      <!-- External REST APIs -->
      <div class="target-box api">
        <div class="target-title">
          <span>🌐 External &amp; Internal APIs</span>
          <span class="pill-tag blue">REST / HTTP</span>
        </div>
        <div class="target-desc">
          Any internal microservice or SaaS API. AGW injects authenticated <code>X-Auth-User</code>, <code>X-Auth-Agent</code>, and <code>X-Delegation-ID</code> headers.
        </div>
        <div class="target-examples">
          <span class="target-pill">Stripe / Billing</span>
          <span class="target-pill">Salesforce API</span>
          <span class="target-pill">Geocoding / Maps</span>
          <span class="target-pill">ERP &amp; Inventory</span>
          <span class="target-pill">Internal Microservices</span>
        </div>
      </div>

      <!-- MCP Servers -->
      <div class="target-box mcp">
        <div class="target-title">
          <span>⚡ MCP Tool Servers</span>
          <span class="pill-tag purple">Model Context</span>
        </div>
        <div class="target-desc">
          Governs tools, prompts, and resources for Claude, Cursor, and custom LLM agents over Streamable HTTP and SSE. Per-tool approval rules.
        </div>
        <div class="target-examples">
          <span class="target-pill">GitHub / Git MCP</span>
          <span class="target-pill">Postgres / SQL MCP</span>
          <span class="target-pill">Slack / Notif MCP</span>
          <span class="target-pill">Custom Tool Servers</span>
        </div>
      </div>

      <!-- Demo CRM Server -->
      <div class="target-box demo">
        <div class="target-title">
          <span>🧪 Built-in Demo CRM</span>
          <span class="pill-tag" style="background:rgba(255,255,255,0.08);color:#94a3b8;">Test Fixture</span>
        </div>
        <div class="target-desc">
          Packaged evaluation service (port :8091). Pre-seeded with customer records to immediately test list, lookup, add, and human-approval delete flows.
        </div>
        <div class="target-examples">
          <span class="target-pill">list_customers</span>
          <span class="target-pill">lookup_customer</span>
          <span class="target-pill">🔒 delete_customer</span>
        </div>
      </div>

      <!-- Forward Proxy / Egress -->
      <div class="target-box" style="border-right-color: #3b82f6;">
        <div class="target-title">
          <span>🛡️ Egress Proxy (:8088)</span>
          <span class="pill-tag blue">Forward</span>
        </div>
        <div class="target-desc">
          HTTP_PROXY forward proxy for agent sandboxes (OpenShell, Docker). Restricts outbound sandbox network access to allowlisted hosts only.
        </div>
      </div>

    </div>

  </div>

  <!-- Bottom Flow Banner -->
  <div class="flow-banner">
    <div class="flow-step s1">① User Signs In via OIDC &amp; Delegates Authority</div>
    <div class="flow-arrow">➔</div>
    <div class="flow-step s2">② Agent Exchanges Secret for Scoped Token</div>
    <div class="flow-arrow">➔</div>
    <div class="flow-step s3">③ In-Line PEP Checks Policy, Caps &amp; Approval</div>
    <div class="flow-arrow">➔</div>
    <div class="flow-step s4">④ Authorized Call Forwarded to Any API / MCP Server</div>
  </div>

</body>
</html>`;

(async () => {
  const browser = await chromium.launch({ executablePath: '/opt/google/chrome/chrome' });
  const page = await browser.newPage({ viewport: { width: 2200, height: 1350 }, deviceScaleFactor: 1 });
  await page.setContent(html);
  await page.waitForTimeout(500);

  const outDir = '/home/stevef/dev/agent-gateway-demo/images';
  const outPathJpg = path.join(outDir, 'conceptual.jpg');
  const outPathPng = path.join(outDir, 'conceptual.png');
  await page.screenshot({ path: outPathJpg, type: 'jpeg', quality: 95 });
  await page.screenshot({ path: outPathPng, type: 'png' });

  // Also copy to main repo docs/images if exists
  const mainRepoDocs = '/home/stevef/dev/agent-gateway/docs/images';
  if (!fs.existsSync(mainRepoDocs)) fs.mkdirSync(mainRepoDocs, { recursive: true });
  fs.copyFileSync(outPathJpg, path.join(mainRepoDocs, 'conceptual.jpg'));
  fs.copyFileSync(outPathPng, path.join(mainRepoDocs, 'conceptual.png'));

  await browser.close();
  console.log('SUCCESS: Rendered diagram to', outPathJpg, 'and', outPathPng);
})();

# Agent Gateway Admin Console — UI Walk-Through Guide

Welcome to the **Agent Gateway Admin Console** (`http://localhost:8083` in local development, or `https://<tenant>.agw.sjfisher.com` in production). 

The Admin Console is a unified control plane for security teams, platform administrators, and AI developers to govern, audit, and safely deploy AI agents connecting to enterprise tools, Model Context Protocol (MCP) servers, and REST APIs.

---

## Table of Contents
1. [Overview & Layout](#1-overview--layout)
2. [Global Header & Traffic-Light Health](#2-global-header--traffic-light-health)
3. [Delegations & Agent Identity Management](#3-delegations--agent-identity-management)
4. [Human-in-the-Loop Approvals](#4-human-in-the-loop-approvals)
5. [System Data Backup & Disaster Recovery](#5-system-data-backup--disaster-recovery)
6. [Protected APIs & MCP Servers Catalog](#6-protected-apis--mcp-servers-catalog)
7. [✨ AI Configuration Assistant (FreeRide)](#7--ai-configuration-assistant-freeride)
8. [5-Step Onboarding Wizard](#8-5-step-onboarding-wizard)
9. [🔑 Live Endpoint Tester & Token Playground](#9--live-endpoint-tester--token-playground)
10. [Tenant Audit Trail & Decision Explorer](#10-tenant-audit-trail--decision-explorer)
11. [Approval Notification Channels (Telegram)](#11-approval-notification-channels-telegram)

---

## 1. Overview & Layout

The console is organized into three primary visual zones:

```
+---------------------------------------------------------------------------------------------------+
|  [Logo] Agent Gateway Console     [Traffic Lights: Gateway | Authz | TokenSvc]    [Identity / Sign-Out] |
+---------------------------------------------------------------------------------------------------+
| LEFT COLUMN:                                      | RIGHT COLUMN:                                  |
|  * Active Delegations & Revocation                |  * System Data Backup & Restore                |
|  * Create Delegation Form                         |  * Pending Approvals Queue (Tap-to-Approve)   |
+---------------------------------------------------+-----------------------------------------------+
| FULL-WIDTH LOWER REGION:                                                                          |
|  * Protected APIs & MCP Servers Inventory Table                                                   |
|  * ✨ AI Configuration Assistant (Freeride LLM Router)                                             |
|  * 5-Step Protection Wizard                                                                       |
|  * 🔑 Interactive Live Endpoint Tester & Token Playground                                          |
|  * Tenant Audit Trail & Decision Explorer (Filter, Inspect, cURL Generator)                       |
+---------------------------------------------------------------------------------------------------+
```

---

## 2. Global Header & Traffic-Light Health

At the top of every screen:

- **Cluster Health Bar (`gwTrafficBar`)**:
  - **Gateway**: Live reachability of the Policy Enforcement Point (PEP).
  - **Authz**: Open Policy Agent (OPA) / policy decision engine health.
  - **TokenSvc**: Cryptographic token issuing service health.
  - *Color indicators*: **Green** (Online & healthy), **Amber** (Degraded or sign-in required for status probe), **Red** (Offline).
- **Verified Identity**:
  - Displays the authenticated email or subject (`Signed in as user@example.com · verified ✓`).
  - In local development mode (`admin_locked: false`), a quick developer user selector (`alice` / `bob`) is provided for testing actor simulation.
- **R&D Demo Pages Toggle**:
  - Toggles the exploratory walkthrough demo (`/demo.html`) and live OPA Policy Playground (`/policy.html`).
- **Refresh (`data-act="loadall"`)**:
  - Refreshes all metrics, active delegations, approvals, inventory, and audit records with one click.

---

## 3. Delegations & Agent Identity Management

Delegations represent cryptographically bound authority granted by a human principal to an autonomous AI agent.

### Active Delegations Table
Located in the upper-left panel:
- **Filters**: Quickly filter delegations by status: `active` (default), `revoked`, `expired`, or `all`.
- **Details Displayed**:
  - **Delegation ID**: Unique reference (e.g., `del-4bf250dae...`).
  - **Principal**: Delegating user identity.
  - **Agent ID**: Authorized agent identifier (e.g., `claude-desktop`, `agent-analyst`).
  - **Resources**: Path prefixes governed (e.g., `/mcp`, `/mcp-emotion`, `/api-geocoding/*`).
  - **Actions**: Explicit permitted actions (`tools/call`, `read`, `create`).
  - **Spend Limit**: Financial ceiling enforced per transaction (e.g., `max 100 EUR`).
  - **Max Depth**: Limits downstream agent-to-agent delegation hops.
  - **Expires**: Automatic expiration timestamp.
- **Revocation**:
  - Clicking **Revoke** immediately invalidates the delegation in Postgres and broadcasts a cache eviction to Redis, terminating agent access instantly.

### Create Delegation Form
Enables manual delegation issuance for testing or pre-provisioning agent runners:
1. Specify the **Target Agent ID**.
2. Define comma-separated **Resources** (supports wildcards, e.g. `/api-*`, `/mcp-*`).
3. Set comma-separated **Actions**.
4. (Optional) Set **Spend limit / order** and **Max depth**.
5. Click **Create** to issue the delegation and display the initial access token.

---

## 4. Human-in-the-Loop Approvals

When an agent attempts a sensitive or held action (e.g., `delete_customer`, a refund over threshold, or `emotion_detection_detailed`), the Gateway pauses execution, returns **HTTP 202 Accepted**, and enters an approval request into the queue.

- **Pending Approvals Panel** (Upper-Right):
  - Displays a live badge with the count of actions awaiting human authorization.
  - **Action Details**: Displays the requesting agent, delegating human, target resource, exact tool/action name, and parameter arguments.
- **Cryptographic Action Binding**:
  - Approval binds strictly to the SHA-256 hash of `(resource + action + argument details)`. If the agent modifies parameters upon retry, the decision is invalidated and a fresh approval is requested.
- **Decision Controls**:
  - Click **Approve** to authorize the agent to proceed on its next poll/retry.
  - Click **Deny** to permanently reject the request.
- **Deep Links**:
  - Approvals support deep-linking (`/#approvals?approval=<id>&action=approve|deny`), enabling one-tap approvals from Slack, Microsoft Teams, or Telegram.

---

## 5. System Data Backup & Disaster Recovery

Located at the top right of the console:

### Exporting Tenant State
- **Download Full Backup (`.json`)**: Exports an atomic snapshot of:
  - OPA Policy rules (`authorizer.rego`).
  - Database tables: active/revoked delegations, pending/decided approvals, and upstreams.
  - Optional: check **Include Audit Events** to bundle compliance records into the export.
- **Component Downloads**: Quick one-click buttons to export **DB Only** or **Policy Only** (`authorizer.rego`).

### Restoring from Backup
- Drop or browse for a `.json` backup bundle or `.rego` policy file.
- **Interactive Backup Preview**:
  - Displays bundle metadata, policy line counts, delegation counts, and approval counts before executing.
  - Checkbox controls allow selective restore (e.g., restore policy only, or restore DB only).
- **Automatic Gateway Traffic Pause**:
  - During database restore, the console automatically signals the Gateway PEP to pause external agent traffic (`/v1/maintenance/pause`), performs the atomic database transaction, and automatically resumes traffic once verified.

---

## 6. Protected APIs & MCP Servers Catalog

Located in the lower section, this panel provides an inventory of all protected upstreams connected to the Gateway.

### Inventory Features
- **Visual Catalog**: Lists all registered MCP servers and REST APIs.
- **Filters**: Filter by upstream type (`MCP Server` vs `REST API`) or search by name.
- **Details per Entry**:
  - **Name & Resource Path**: e.g., `emotion` mapped to `/mcp-emotion`, `geocoding` mapped to `/api-geocoding`.
  - **Mode**: URL proxy (`http://...`) or In-Namespace Kubernetes Container.
  - **Policy Guardrails Popover**: Hover or click to see allowed actions, held actions, and financial ceilings enforced for that upstream.
- **Actions Menu**:
  - **Test**: Opens the Endpoint Tester pre-configured for this upstream.
  - **Delete**: Unregisters the upstream and tears down its associated routing.

---

## 7. ✨ AI Configuration Assistant (FreeRide)

The AI Configuration Assistant is powered by **FreeRide Proxy**, an OpenAI-compatible router running alongside the gateway that connects to models (Google Gemini, Groq, OpenRouter, Cerebras, etc.) without complex cloud setup.

### How to Use the AI Assistant
1. Click **✨ AI Config Assistant (Freeride)** in the catalog header.
   - *Status Pill*: Shows `[online]` (green) when FreeRide is healthy, or `[offline]` if unreachable.
2. **Choose a Preset or Describe Your Requirement**:
   - Built-in presets available with one click:
     - **Emotion Analysis MCP**: Dedicated MCP gateway on `/mcp-emotion` with basic tools allowed and detailed analysis held for human review.
     - **Customer CRM MCP Server**: CRM tool with `get_customer` allowed and `delete_customer` held.
     - **Geocoding REST API**: Open-Meteo search proxy on `/api-geocoding/v1/*`.
     - **Refunds & Billing API**: Financial endpoint with transactions over 100 EUR held.
   - **Custom Natural Language Prompting**: Type any requirement in plain English (e.g., *"Protect our Internal Stripe Payments API, allowing charges under 500 EUR but holding any customer refund for manager consent"*).
3. Click **✨ Ask Freeride AI to Generate**.
4. **Inspect Recommendations**:
   - The assistant outputs recommended route prefixes, allowed actions, approval actions, policy rules, and human-readable explanations.
5. **Apply**:
   - Click **Use in Protection Wizard** to populate the 5-step onboarding wizard.
   - Click **⚡ Fast-Track Provision** to immediately register the upstream and apply policy rules.

---

## 8. 5-Step Onboarding Wizard

Click **+ Protect API or MCP Server (Wizard)** to configure an upstream manually or review an AI-generated configuration:

| Step | Title | Purpose |
| :--- | :--- | :--- |
| **1** | **Upstream Service** | Choose Service Kind (`MCP Server` or `REST API`), Connection Mode (`Direct URL` or `Container Image`), name slug, and endpoint URL. Presets auto-detect host and port. |
| **2** | **Tool Discovery** | Automatically probes the upstream (`tools/list` for MCP, OpenAPI for REST). Highlights **Destructive Actions** (delete, remove, drop, detailed) automatically. |
| **3** | **Access & Guardrails** | Select which tools are **Freely Permitted** vs **Require Human Approval**. Set parameter spend limits and delegation validity. |
| **4** | **Provision & Deploy** | Deploys the upstream. In Kubernetes, automatically creates the dedicated PEP deployment, ClusterIP service, and Ingress route. In Docker/Local, updates routing and policy. |
| **5** | **Test & Verify** | Generates verified cURL scripts across 4 tabs: Tool Discovery, Delegation Creation, Token Minting, and Governed Execution. |

---

## 9. 🔑 Live Endpoint Tester & Token Playground

Test tools and policies directly from the browser without leaving the console:

1. Click **🔑 Get Token & Test Endpoints** to toggle the testing panel.
2. **Target Service**:
   - The dropdown automatically discovers all registered services (`/mcp`, `/mcp-emotion`, `/api-geocoding`, etc.).
3. **Preset Scenarios**:
   - Select predefined test cases:
     - *Allowed Tool Call*: verifies permitted tools succeed immediately (HTTP 200).
     - *Approval-Held Call*: triggers a human approval hold (HTTP 202).
     - *Over-Limit Call*: tests policy threshold rejection.
4. **Token Generation**:
   - Click **🔑 Mint Token for Scenario** to automatically generate a valid delegation and audience-scoped bearer JWT.
5. **Execute**:
   - Click **Send Governed Request** to dispatch the call through the Gateway PEP.
6. **Response Viewer**:
   - Displays verdict badge (**ALLOW**, **HELD 202**, or **DENY**), latency in milliseconds, exact request URI, and syntax-highlighted JSON output.
   - If an action is held, an interactive alert directs you straight to the Pending Approvals panel above.

---

## 10. Tenant Audit Trail & Decision Explorer

Every single call across all protected MCP servers and APIs is audited with cryptographic provenance.

### Filtering Audit Events
- **Outcome Filter**: Filter by `all outcomes`, `allow`, `approval_required (held)`, `deny`, or `error`.
- **Resource Filter**: Filter by specific protected endpoint (e.g. `/mcp`, `/mcp-emotion`).
- **Action / Tool Input**: Filter by tool name (e.g., `delete_customer`, `emotion_detection_basic`).
- **Agent & User ID**: Filter by specific agent identifier or human principal.
- **Search**: Free-text search matching reason, policy ID, or client application.
- **Row Limit**: Select between 50, 100, 250, or 500 rows.

### Structured Log Inspection
- Each row displays: **Timestamp**, **Outcome Pill**, **Resource**, **Action / Tool**, **Agent & Client**, **User**, **Policy Verdict / Reason**, and **Latency**.
- Click **Inspect** on any row to expand the full structured JSON audit record.
- Click **Copy JSON** to copy the event for SIEM or incident response.

### Equivalent cURL Generator
- Click **Show Equivalent cURL** to see exact commands for querying audit events:
  - **Via Console Session API**: for automated scripts reusing your browser session.
  - **Via Direct Gateway Operator API**: for SIEM integrations (Splunk, Datadog) using `X-Admin-Token`.

---

## 11. Approval Notification Channels (Telegram)

Configure real-time push alerts when actions require human approval:

1. Locate the **Approval notifications — Telegram** panel in the console.
2. Enter your **Bot Token** (obtained from `@BotFather`).
3. Enter your **Chat ID** (personal chat or security operations room).
4. Click **Test & Save Configuration**:
   - The Gateway validates the token against Telegram's API and dispatches a test message.
   - In Kubernetes, credentials are saved securely in your tenant namespace Secret.
5. When an agent attempts an action flagged for approval, your Telegram bot instantly sends an alert with action details and deep-links to Approve or Deny.

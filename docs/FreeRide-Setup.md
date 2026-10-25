# Setting Up FreeRide AI for Agent Gateway

The **AI Configuration Assistant** in the Agent Gateway Console (`web:8083`) is powered by **FreeRide Proxy**, an OpenAI-compatible LLM router that connects to free-tier and commercial AI inference providers (Google Gemini, OpenRouter, Groq, Cerebras, NVIDIA NIM, Cloudflare Workers AI, and Ollama Cloud).

---

## 1. How It Works

1. **Docker Compose Service (`freeride`)**: Runs `stevef1uk/freeride:1.4.0` alongside Agent Gateway services on internal port `11434`.
2. **Dynamic UI Health Check (`GET /api/ai/status`)**: The console dynamically probes `http://freeride:11434/api/hello`.
   - **When FreeRide is online**: The `✨ AI Config Assistant (Freeride)` button is **enabled** with a green `online` pill.
   - **When FreeRide is offline or unconfigured**: The button is **disabled** with an amber/gray `offline` pill, preventing confusing failures.
3. **Natural Language Policy Generation**: You describe an API or MCP server in plain English. FreeRide generates:
   - Route path definitions (`/api-<name>/*` or `/mcp-<name>*`).
   - Least-privilege actions (`read`, `create`, `list`, `tools/call`).
   - Human-in-the-loop approval rules (e.g. destructive actions like `delete_customer` or financial limits like `max 100 EUR`).
   - One-click loading into the 5-Step Wizard or instant provisioning.

---

## 2. Configuring `.env` Before Starting Docker Compose

Before running `docker compose up -d`, configure `demo/.env`.

### Step A: Create `.env` from template
```bash
cd demo
cp .env.example .env
```

### Step B: Configure Desired Provider API Keys
Supply an API key for at least one of the supported providers in `demo/.env`:

```bash
# 1. Google Gemini (Free tier recommended)
# Get key from https://aistudio.google.com/app/apikey
GEMINI_API_KEY=AIzaSy...

# 2. OpenRouter (Access to dozens of free & commercial models)
# Get key from https://openrouter.ai/keys
OPENROUTER_API_KEY=sk-or-v1-...

# 3. Groq (Ultra-fast Llama 3 models)
# Get key from https://console.groq.com/keys
GROQ_API_KEY=gsk_...

# 4. Cerebras (Ultra-high throughput)
CEREBRAS_API_KEY=csk-...

# 5. NVIDIA NIM
NVIDIA_API_KEY=nvapi-...

# 6. Cloudflare Workers AI
CLOUDFLARE_ACCOUNT_ID=your-account-id
CLOUDFLARE_API_TOKEN=your-api-token
```

### Step C: Configure Target Model (Optional)
By default, the assistant requests `gpt-4o` (which FreeRide routes to the best capable model among your configured providers). You can pin a specific model and provider label:

```bash
# Model identifier to request from FreeRide router:
FREERIDE_MODEL=gpt-4o

# Display label in Console header:
FREERIDE_PROVIDER=FreeRide
```

---

## 3. Starting the Stack with FreeRide

Start the complete stack with FreeRide enabled:

```bash
cd demo
docker compose up -d
```

Check FreeRide health:
```bash
docker compose logs freeride
curl -fsS http://localhost:11434/api/hello
```
Expected output:
```json
{"status":"ok","version":"1.4.0"}
```

Open the Admin Console at **`http://localhost:8083`**:
1. Check the **Protected APIs & MCP Servers** section.
2. The button `✨ AI Config Assistant (Freeride) [online]` will be active.
3. Click to open the assistant, select a preset (e.g., *Customer CRM MCP Server* or *Users REST API*), and click **✨ Ask Freeride AI to Generate**.

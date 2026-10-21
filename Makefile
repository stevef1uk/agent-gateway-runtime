# Makefile for the agent-gateway-demo repository.
#
# The demo API's source lives at demo/api (standalone Go module) and the
# performance benchmark at demo/bench (standalone Go module). The
# agent-gateway product images (authz/tokensvc/gateway/web) are built and
# published from the product repo (agent-gateway/Makefile) — they are
# pulled here, never built.

SHELL := /bin/bash

# Where to publish the demo API image. Push to your own registry with:
#   make push REGISTRY=ghcr.io/yourname IMAGE_NS=your-prefix API_VERSION=...
# Consume your copy by setting DEMOAPI_IMAGE (compose) and the image refs in
# k3s/agentgw.yaml (k3s). See README "Building and publishing the demo API".
REGISTRY         ?= docker.io/stevef1uk
IMAGE_NS         ?= agent-gateway
API_VERSION      ?= 1.0.6
API_IMAGE        := $(REGISTRY)/$(IMAGE_NS)-demoapi
MCPSRV_VERSION   ?= 1.0.0
MCPSRV_IMAGE     := $(REGISTRY)/$(IMAGE_NS)-mcpsrv
BUILDER          ?= agent-gateway-builder
PLATFORMS        ?= linux/amd64,linux/arm64
NODE             ?= 192.168.1.74

# Container engine: docker (default) or podman. Auto-detected when unset.
# Podman note: rootless compose needs its API socket up
# (systemctl --user start podman.socket); image builds here are host-arch only.
ENGINE ?= $(shell command -v docker >/dev/null 2>&1 && echo docker || echo podman)
COMPOSE          ?= $(ENGINE) compose

# Arguments passed through to the benchmark by `make bench` (see docs/Benchmarking.md).
BENCH_ARGS       ?=

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: test
test: ## Vet + test the demo API and MCP server, and vet the benchmark tool
	cd demo/api && go vet ./... && go test ./...
	cd demo/mcp && go vet ./... && go test ./...
	cd demo/bench && go vet ./...

.PHONY: image
image: ## Build the demo API image (host arch — docker or podman per ENGINE)
	$(ENGINE) build -f demo/api/Dockerfile -t $(API_IMAGE):$(API_VERSION) demo/api

.PHONY: image-mcp
image-mcp: ## Build the demo MCP server image (host arch — docker or podman per ENGINE)
	$(ENGINE) build -f demo/mcp/Dockerfile -t $(MCPSRV_IMAGE):$(MCPSRV_VERSION) demo/mcp

.PHONY: push
push: ## Build + push the demo API (multi-arch) — the buildx builder must exist
	docker buildx build --builder $(BUILDER) --platform $(PLATFORMS) --pull \
		-f demo/api/Dockerfile \
		-t $(API_IMAGE):$(API_VERSION) -t $(API_IMAGE):latest --push demo/api

.PHONY: push-mcp
push-mcp: ## Build + push the demo MCP server (multi-arch) — the buildx builder must exist
	docker buildx build --builder $(BUILDER) --platform $(PLATFORMS) --pull \
		-f demo/mcp/Dockerfile \
		-t $(MCPSRV_IMAGE):$(MCPSRV_VERSION) -t $(MCPSRV_IMAGE):latest --push demo/mcp

.PHONY: verify-arch
verify-arch: ## Assert the published image's arm64 variant runs arm64 code
	@for ref in $(API_IMAGE):$(API_VERSION); do \
	  manifest=$$(docker manifest inspect $$ref); \
	  for m in $$(echo $$manifest | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(m2["digest"]) for m2 in d["manifests"] if m2.get("platform",{}).get("architecture")=="arm64"]'); do \
	    docker pull -q $(API_IMAGE)@$$m >/dev/null; \
	    container=$$(docker create $(API_IMAGE)@$$m true 2>/dev/null); \
	    docker cp $$container:/app/demoapi /tmp/demoapi-arch-check >/dev/null; \
	    docker rm $$container >/dev/null; \
	  done; \
	  if od -A x -t x1 -j 18 -N 2 /tmp/demoapi-arch-check | grep -q 'b7 00'; then \
	    echo "$$ref: arm64 variant is aarch64 ✓"; \
	  else \
	    echo "$$ref: arm64 variant is NOT aarch64 ✗" && exit 1; \
	  fi; \
	done

.PHONY: protected-api
protected-api: ## Run the protected-API demo (compose)
	./demo/protected-api-demo.sh

.PHONY: mcp-demo
mcp-demo: ## Run Demo 9 — MCP under the gateway (add ARGS="--no-openclaw" to skip the agent leg)
	./demo/mcp-demo.sh $(ARGS)

# ---------------------------------------------------------------------------
# OpenClaw in an NVIDIA OpenShell sandbox (demo/openclaw-sandbox.sh).
#
# The sandbox is the isolation boundary: OpenClaw runs as an unprivileged user
# in a container with no host filesystem, no Docker socket, and default-deny
# egress. Requires Docker + the `openshell` CLI (https://docs.nvidia.com/openshell).
# The API key comes from demo/.env (NVIDIA_API_KEY) or the environment.
# ---------------------------------------------------------------------------
OPENCLAW_SH := ./demo/openclaw-sandbox.sh

.PHONY: openclaw-image
openclaw-image: ## Build the OpenClaw sandbox image
	$(OPENCLAW_SH) build

.PHONY: openclaw-up
openclaw-up: ## Create the OpenShell sandbox and start the OpenClaw gateway
	$(OPENCLAW_SH) up

.PHONY: openclaw-configure
openclaw-configure: ## Configure the model provider + egress allowlist inside the sandbox
	$(OPENCLAW_SH) configure

.PHONY: openclaw-chat
openclaw-chat: ## Send one message: make openclaw-chat MSG="hello"
	$(OPENCLAW_SH) chat "$(MSG)"

.PHONY: openclaw-chat-gateway
openclaw-chat-gateway: ## Chat via Agent Gateway proxy (SSO → delegation → token): make openclaw-chat-gateway MSG="hello"
	$(OPENCLAW_SH) chat-gateway "$(MSG)"

.PHONY: openclaw-egress-test
openclaw-egress-test: ## Prove egress rules from the sandbox [GW=--gateway for Agent Gateway checks; add --no-human to skip approval waits]
	./demo/openclaw-egress-test.sh $(GW)

.PHONY: openclaw-shell
openclaw-shell: ## Interactive shell inside the sandbox
	$(OPENCLAW_SH) shell

.PHONY: openclaw-status
openclaw-status: ## Sandbox + gateway health
	$(OPENCLAW_SH) status

.PHONY: openclaw-restart
openclaw-restart: ## Delete + recreate + configure (fixes stale sessions)
	$(OPENCLAW_SH) restart

.PHONY: openclaw-down
openclaw-down: ## Delete the OpenShell sandbox
	$(OPENCLAW_SH) down

.PHONY: openclaw-demo
openclaw-demo: openclaw-image openclaw-up openclaw-configure ## Full path: image → sandbox → provider → chat
	$(OPENCLAW_SH) chat "Reply with exactly: hello from the sandbox"

.PHONY: human-delegation-demo
human-delegation-demo: ## Demo 8 — OpenClaw pays an invoice (one fraudulent) through the gateway; add ARGS="--no-human" for unattended
	./demo/human-delegation-demo.sh $(ARGS)

.PHONY: security-scan
security-scan: ## OWASP ZAP baseline scan of the core containers → security/results/
	./security/zap-scan.sh

.PHONY: security-scan-mcp
security-scan-mcp: ## OWASP ZAP scan of just the new MCP services (Demo 9)
	./security/zap-scan.sh TARGETS="mcpsrv=8091 gateway-mcp=8085"

.PHONY: bench
bench: ## Benchmark the gateway: both engines (built-in + OPA)
	./demo/bench-engines.sh $(BENCH_ARGS)

.PHONY: protected-api-k3s
protected-api-k3s: ## Run the protected-API demo against the k3s node
	./demo/protected-api-demo.sh --node $(NODE)

.PHONY: pull-images
pull-images: ## Refresh the published gateway-stack images
	$(COMPOSE) -f demo/docker-compose.yml -f demo/docker-compose.opa.yml pull

.PHONY: k3s-apply
k3s-apply: ## Apply k3s/agentgw.yaml (namespace/secret from k3s/README.md must exist)
	kubectl apply -f k3s/agentgw.yaml && kubectl -n agentgw get pods

.PHONY: smoke-k3s
smoke-k3s: ## Run the full-lifecycle smoke on the k3s node
	bash k3s/smoke.sh $(NODE)

k3s-builder-root: ## (informational) the multi-arch builder used by push lives in the product repo
	@docker buildx ls | grep agent-gateway-builder

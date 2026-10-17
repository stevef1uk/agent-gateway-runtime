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
API_VERSION      ?= 1.0.4
API_IMAGE        := $(REGISTRY)/$(IMAGE_NS)-demoapi
BUILDER          ?= agent-gateway-builder
PLATFORMS        ?= linux/amd64,linux/arm64
NODE             ?= 192.168.1.74
COMPOSE          ?= docker compose

# Arguments passed through to the benchmark by `make bench` (see docs/Benchmarking.md).
BENCH_ARGS       ?=

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: test
test: ## Vet + test the demo API, and vet the benchmark tool
	cd demo/api && go vet ./... && go test ./...
	cd demo/bench && go vet ./...

.PHONY: image
image: ## Build the demo API image (host arch)
	docker build -f demo/api/Dockerfile -t $(API_IMAGE):$(API_VERSION) demo/api

.PHONY: push
push: ## Build + push the demo API (multi-arch) — the buildx builder must exist
	docker buildx build --builder $(BUILDER) --platform $(PLATFORMS) --pull \
		-f demo/api/Dockerfile \
		-t $(API_IMAGE):$(API_VERSION) -t $(API_IMAGE):latest --push demo/api

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

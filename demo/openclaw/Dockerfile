# ============================================================================
# OpenClaw, preinstalled for running under NVIDIA OpenShell.
#
# OpenShell replaces this image's ENTRYPOINT with its own supervisor at
# runtime, which then execs the start command you pass after `--` on
# `openshell sandbox create`. So there is no ENTRYPOINT/CMD here on purpose.
#
# OpenShell's container contract (see OpenShell "Bring Your Own Container"):
#   - a non-root USER with a passwd entry
#   - a writable /sandbox workspace owned by that user
#   - iproute2 installed, for network-namespace isolation
#   - a normal Linux base (no distroless / FROM scratch)
#
# Build:
#   docker build -t agent-gateway-demo/openclaw:latest demo/openclaw
# ============================================================================

FROM nvcr.io/nvidia/base/ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Node 22 (OpenClaw needs a modern Node; Ubuntu 24.04 ships 18).
# iproute2 is required by OpenShell for network-namespace isolation.
# Node 22 (OpenClaw needs a modern Node; Ubuntu 24.04 ships 18).
# iproute2 is required by OpenShell for network-namespace isolation.
#
# Two-layer apt bootstrap:
#   1. Docker Desktop's built-in proxy (http.docker.internal:3128) caches
#      plain-HTTP fetches; a cache that hiccups mid-mirror-sync re-serves
#      stale pool copies -> "Hash Sum mismatch" aborts the whole build
#      (expected on new arm64 clones). So the bootstrap installs only the
#      CA bundle over HTTP, forcing each fetch fresh in the proxy
#      (Acquire::http::No-Cache) and retrying hard (Acquire::Retries).
#   2. With certs present, flip the Ubuntu mirrors to HTTPS — end-to-end TLS
#      cannot be cached/rewritten by any deli-plate middlebox — and fetch
#      everything else over https.
RUN rm -rf /var/lib/apt/lists/* \
    && apt-get update \
    && apt-get install -y --no-install-recommends -o Acquire::Retries=5 -o Acquire::http::No-Cache=true ca-certificates \
    && sed -i -e 's|^URIs: http://|URIs: https://|' /etc/apt/sources.list.d/*.sources \
              -e '/^deb /s|^deb http://|deb https://|' /etc/apt/sources.list 2>/dev/null || true \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get update \
    && apt-get install -y --no-install-recommends -o Acquire::Retries=5 \
        curl git jq \
        iproute2 \
        openssh-client \
        python3 \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install OpenClaw globally as root so it lands on the default PATH for all
# users. uid 1001 because 1000 is taken by the base image's `ubuntu` user.
RUN npm install -g openclaw \
    && npm cache clean --force \
    && useradd --create-home --shell /bin/bash --uid 1001 sandbox \
    && install -d -o sandbox -g sandbox /sandbox /sandbox/.openclaw

# Pre-seed a *configured* OpenClaw state so the gateway boots with the model
# provider already defined. (The start command still needs --allow-unconfigured:
# without it the gateway refuses to boot against this minimal config and exits
# 78. The flag only skips full-onboarding validation; this config still applies.)
#
# The API key is an env SecretRef: only the env var *name* is written here,
# never the secret itself. The runtime must provide PROVIDER_API_KEY in the
# gateway process's environment (the demo script injects it via
# `openshell sandbox create --env`).
#
# IMPORTANT — model id vs reference: OpenClaw prefixes the provider key
# ("nvidia") onto the stored model id when calling the API. So the stored
# `id`/`name` must be the BARE model id, while agents.defaults.model is the
# provider-prefixed reference ("nvidia/<bare-id>"). Getting this backwards
# sends "nvidia/nvidia/..." to the API.
#
# Point PROVIDER_MODEL at build time to target any other OpenAI-compatible
# model; it must be the bare id (no provider prefix).
ARG PROVIDER_BASE_URL="https://integrate.api.nvidia.com/v1"
ARG PROVIDER_MODEL="nemotron-3-super-120b-a12b"
RUN printf '%s\n' "{\
  \"models\": {\"providers\": {\"nvidia\": {\
      \"baseUrl\": \"${PROVIDER_BASE_URL}\",\
      \"apiKey\": {\"source\": \"env\", \"provider\": \"default\", \"id\": \"PROVIDER_API_KEY\"},\
      \"models\": [{\
        \"id\": \"${PROVIDER_MODEL}\",\
        \"name\": \"${PROVIDER_MODEL}\",\
        \"contextWindow\": 131072,\
        \"maxTokens\": 4096\
      }]\
  }}},\
  \"agents\": {\"defaults\": {\"model\": \"nvidia/${PROVIDER_MODEL}\"}}\
}" > /sandbox/.openclaw/openclaw.json \
    && chown sandbox:sandbox /sandbox/.openclaw/openclaw.json

USER sandbox
WORKDIR /sandbox

# Fail the build early if the binary is not runnable on the default PATH.
RUN openclaw --version

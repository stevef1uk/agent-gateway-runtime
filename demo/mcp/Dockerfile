# Demo MCP server — deliberately simple: this is a stand-in for the
# CUSTOMER's own MCP server (the thing Agent Gateway protects), not a
# vendor-delivered component, so no secure-packager encryption, no licence
# token, no entrypoint ceremony. Standalone module; source in this directory.
# (Same pattern as demo/api.)
FROM --platform=$BUILDPLATFORM golang:1.26.9-bookworm AS builder

# Auto-filled per variant by buildx; without these declarations the build
# falls back to the host platform and every variant ships amd64 binaries.
ARG TARGETOS
ARG TARGETARCH

# WORKDIR is REQUIRED: without it go silently falls into GOPATH mode and the
# cross-compile is meaningless.
WORKDIR /src
# Cross-compile settings as stage ENV, NOT as RUN prefix bindings.
ENV CGO_ENABLED=0 \
    GOOS=${TARGETOS} \
    GOARCH=${TARGETARCH}

COPY go.mod go.sum main.go main_test.go ./
# Own cache (not builder-wide defaults), as in demo/api.
RUN --mount=type=cache,target=/go/buildcache-mcpsrv \
    GOCACHE=/go/buildcache-mcpsrv \
    GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}" \
    go mod download \
    && go vet ./... \
    && go test ./... \
    && go build -ldflags="-s -w" -o /out/mcpsrv .

FROM alpine:3.22

RUN apk add --no-cache ca-certificates tzdata curl \
    && addgroup -g 1000 app && adduser -D -u 1000 -G app app

COPY --from=builder /out/mcpsrv /app/mcpsrv
RUN chown -R app:app /app

USER app
EXPOSE 8091

ENV MCP_HOST=0.0.0.0 \
    MCP_PORT=8091 \
    MCP_TRANSPORT=streamable-http

HEALTHCHECK --interval=5s --timeout=3s --start-period=3s --retries=5 \
    CMD curl -f http://localhost:8091/health || exit 1

ENTRYPOINT ["/app/mcpsrv"]

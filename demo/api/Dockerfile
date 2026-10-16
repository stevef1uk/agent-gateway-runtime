# Demo protected API — deliberately simple: this is a stand-in for the
# CUSTOMER's own API (the thing Agent Gateway protects), not a
# vendor-delivered component, so no secure-packager encryption, no licence
# token, no entrypoint ceremony. Standalone module; source in this directory.
FROM --platform=$BUILDPLATFORM golang:1.26.9-bookworm AS builder

# Auto-filled per variant by buildx; without these declarations the build
# falls back to the host platform and every variant ships amd64 binaries.
ARG TARGETOS
ARG TARGETARCH

# WORKDIR is REQUIRED: without it go silently falls into GOPATH mode and the
# cross-compile is meaningless.
WORKDIR /src
# Cross-compile settings as stage ENV, NOT as RUN prefix bindings: prefix
# assignments apply only to the first command of a chain, so `go vet && go
# test && go build` would otherwise build the later commands for the host.
ENV CGO_ENABLED=0 \
    GOOS=${TARGETOS} \
    GOARCH=${TARGETARCH}

COPY go.mod main.go main_test.go ./
# Own cache (not builder-wide defaults): a shared GOPATH-mode cache once
# served a stale amd64 action to this cross-compile.
RUN --mount=type=cache,target=/go/buildcache-demoapi \
    GOCACHE=/go/buildcache-demoapi \
    go vet ./... \
    && go test ./... \
    && go build -ldflags="-s -w" -o /out/demoapi .

FROM alpine:3.22

RUN apk add --no-cache ca-certificates tzdata \
    && addgroup -g 1000 app && adduser -D -u 1000 -G app app

COPY --from=builder /out/demoapi /app/demoapi
RUN chown -R app:app /app

USER app
EXPOSE 8090
ENTRYPOINT ["/app/demoapi"]

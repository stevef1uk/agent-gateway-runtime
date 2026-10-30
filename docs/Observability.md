# Observability

The gateway, authorization service, token service and web console emit JSON
operational logs to stderr. Request completion logs include a locally generated
`request_id`, method, route template, status and duration. Each non-healthcheck
response carries that ID in `X-Request-ID`. Existing `log.Printf` messages are
bridged into the same JSON format; request-aware `slog` calls also include
`trace_id` and `span_id` when tracing is enabled.

Security audit records remain separate: they retain their existing persistence,
contents and sampling-independent writes. With tracing enabled, audit records
also contain `trace_id` and `span_id`. Postgres stores these in the existing
`data` JSON column, so no database migration is required. Audit writes detached
from a completed HTTP request retain its trace context.

## Image versions

Use these versions or later releases containing OpenTelemetry support. Older
images do not gain the capability just by setting environment variables.

| Service | Demo/evaluation image | Managed-service image |
|---|---|---|
| Authorization | `stevef1uk/agent-gateway-authz:1.0.13` | `stevef1uk/agent-gateway-authz_m:1.0.16` |
| Token service | `stevef1uk/agent-gateway-tokensvc:1.0.7` | `stevef1uk/agent-gateway-tokensvc_m:1.0.8` |
| Gateway (including MCP/egress) | `stevef1uk/agent-gateway-gateway:1.0.33` | `stevef1uk/agent-gateway-gateway_m:1.0.37` |
| Web console | `stevef1uk/agent-gateway-web:1.0.56` | `stevef1uk/agent-gateway-web_m:1.0.69` |

Managed images continue to require the managed decryption key and tenant
licence. The demo Compose stack uses evaluation images and demo credentials.

## Docker Compose quickstart

The repository includes an optional
[`docker-compose.observability.yml`](../demo/docker-compose.observability.yml)
override and a pinned OpenTelemetry Collector image. From the repository root:

```sh
docker compose -f demo/docker-compose.yml -f demo/docker-compose.observability.yml pull
docker compose -f demo/docker-compose.yml -f demo/docker-compose.observability.yml up -d
```

To combine observability with the OPA policy-engine demo, include all three files:

```sh
docker compose -f demo/docker-compose.yml -f demo/docker-compose.opa.yml \
  -f demo/docker-compose.observability.yml up -d
```

The override enables export on authz, tokensvc, web and all three gateway
instances. It preserves their existing environment settings, keys, licences and
upstream routes. No collector port is published on the host; the services reach
`http://otel-collector:4318` over the Compose network.

Generate traffic by opening `http://localhost:8083/` or running `demo/demo.sh`.
Health checks do not generate telemetry. Inspect the resulting logs:

```sh
docker compose -f demo/docker-compose.yml -f demo/docker-compose.observability.yml \
  logs --since=5m otel-collector gateway authz tokensvc web
curl -sS -D - -o /dev/null http://localhost:8080/orders
```

The curl request can be denied without a token and still produces a request
log/span; its response includes `X-Request-ID`. Collector logs report received
spans and metric points. Metrics are sent every five seconds in this demo
override; traces are batched. The sample collector uses the `debug` exporter,
which logs summaries rather than storing a searchable trace history. For a UI,
configure a backend exporter in
[`demo/otel-collector.yaml`](../demo/otel-collector.yaml) for your chosen tracing
and metrics platform.

For an existing collector, set `OTEL_EXPORTER_OTLP_ENDPOINT` in `demo/.env` (or
export it in your shell) to its reachable base URL and rerun the same `up -d`
command. The override explicitly passes this variable into each service; adding
it only to `.env` without the override does not configure the containers.
Collector authentication headers can be added to the service environments using
`OTEL_EXPORTER_OTLP_HEADERS`. Recreate containers with `up -d` after changing
configuration; `restart` alone does not reload Compose environment settings.

To disable export while retaining the override, run the same command with
`OTEL_ENABLED=false`. JSON operational logs remain available.

## Enable OTLP/HTTP export

Export is **off by default** outside the optional Compose override. Set these
variables on each service process or container to send telemetry to an
OpenTelemetry Collector or compatible backend:

```sh
OTEL_ENABLED=true
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=preprod,service.namespace=agent-gateway
```

The service names default to `gateway`, `authz`, `tokensvc` and `web`. Optionally
set `OTEL_SERVICE_NAME` separately on each service; do not give every service the
same override. The exporter appends `/v1/traces` and `/v1/metrics` to the base
endpoint. Plain HTTP is suitable for a trusted internal collector; use an HTTPS
URL for a remote collector.

Supported settings:

| Variable | Purpose |
|---|---|
| `OTEL_ENABLED` | Set `true` to install trace and metric exporters. |
| `OTEL_SDK_DISABLED` | `true` overrides enablement and disables both exporters. |
| `OTEL_SERVICE_NAME` | Override this process's service name. |
| `OTEL_RESOURCE_ATTRIBUTES` | Static resource attributes, such as environment or service version. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Collector base URL; SDK default is `http://localhost:4318`. |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | Override the complete trace export URL. |
| `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` | Override the complete metric export URL. |
| `OTEL_EXPORTER_OTLP_HEADERS` | Export authentication headers, e.g. `Authorization=Bearer%20TOKEN`. |
| `OTEL_TRACES_EXPORTER` | `none` disables traces; otherwise this integration uses OTLP/HTTP. |
| `OTEL_METRICS_EXPORTER` | `none` disables metrics; otherwise this integration uses OTLP/HTTP. |
| `OTEL_TRACES_SAMPLER` | Standard Go SDK sampler, e.g. `parentbased_traceidratio`. |
| `OTEL_TRACES_SAMPLER_ARG` | Root sampling ratio, e.g. `0.1` for 10% with the ratio sampler. |
| `OTEL_METRIC_EXPORT_INTERVAL` | Periodic export interval in milliseconds (SDK default: 60000). |

This integration uses HTTP/protobuf exporters; setting an OTLP protocol variable
does not switch it to gRPC. Normal operation uses batch trace export with a
bounded, non-blocking queue and periodic metric export. Collector failures do
not determine authorization outcomes. Export requests have a three-second
timeout; normal process shutdown allows up to five seconds to flush telemetry
after HTTP handlers drain. Fatal process exits cannot guarantee a flush.

## Kubernetes / managed-service configuration

Upgrade the service images first. Set the same environment values on each
relevant Deployment, using your collector's cluster DNS name. For example,
replace `otel-collector.observability.svc.cluster.local` with your collector's
actual Service name, and adjust the namespace and Deployment list for your tenant:

```sh
kubectl -n tenant-preprod set env deployment/authz deployment/tokensvc \
  deployment/web deployment/gateway-mcp deployment/gateway-mcp-emotion \
  OTEL_ENABLED=true \
  OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.observability.svc.cluster.local:4318 \
  OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=preprod,service.namespace=tenant-preprod
kubectl -n tenant-preprod rollout status deployment/authz
kubectl -n tenant-preprod rollout status deployment/tokensvc
kubectl -n tenant-preprod rollout status deployment/web
kubectl -n tenant-preprod rollout status deployment/gateway-mcp
kubectl -n tenant-preprod rollout status deployment/gateway-mcp-emotion
```

Store collector authentication headers in a Kubernetes Secret and reference them
with `secretKeyRef` when required. Persist environment settings in your own
Deployment manifests or GitOps configuration after trying them interactively.
The base k3s manifests do not install a collector or enable export automatically.
To turn export off, set `OTEL_ENABLED=false` on those Deployments and wait for
the rollout. Operational JSON logs continue without a collector.

## Initial instrumentation

Traces cover inbound HTTP requests in all four services, outgoing authz client
calls, gateway upstream forwarding, egress HTTP forwarding and console calls
made through its default HTTP client. Server spans follow W3C `traceparent`
context, and instrumented outgoing calls inject it. Baggage is neither extracted
nor forwarded by those transports. Client spans remain open until response
bodies finish or close, including streamed responses.

For example, an instrumented console request can produce:

```text
web: POST /api/gateway/call
  console outbound POST
    gateway: POST /*
      authz POST
        authz: POST /v1/check
      upstream POST
```

The authorization span measures the whole service call. Separate policy-engine,
Postgres and Redis spans are future instrumentation points. Asynchronous
notifications and later approval decisions are not yet linked into the original
trace; use the existing audit `approval_id` to correlate those events. CONNECT
tunnels have an inbound span but their encrypted contents are not inspected.

Metrics exported by the initial integration:

| Instrument | Type | Dimensions |
|---|---|---|
| `http.server.requests` | Counter | Method, route template, response status |
| `http.server.request.duration` | Histogram, seconds | Method, route template, response status |
| `agent_gateway.audit.events` | Counter of audit write attempts | Outcome: allow, deny, approval_required, error |

HTTP histogram buckets cover 5ms to 60s. Durations include the request handler's
lifetime, so streamed responses and CONNECT tunnels may be long-lived. Health
checks at `/healthz` bypass instrumentation and request completion logging.
Approval queue depth and human wait time are not included in these HTTP metrics.

## Data handling and log collection

Automatic HTTP telemetry records no raw URL, query string, request/response
body, authorization header, cookie, raw network error or tool arguments. Routes
use chi templates (`/v1/delegations/{id}`), with `unmatched` as the fallback.
Arbitrary HTTP methods become `_OTHER`. Request, user, delegation and tenant IDs
are not metric labels. The existing security audit records retain their own
identity and authorization details.

Operational logs go to stderr and can be collected by the deployment's existing
log agent or a Collector filelog receiver. Direct OTLP log export is not enabled.
Trace IDs in the JSON logs allow a supporting backend to link logs to traces.
Legacy messages preserve their existing text; only request-aware log calls get
automatic per-request correlation. Telemetry export errors are logged using
generic messages so collector URLs or authentication details are not echoed.

## Minimal collector configuration

For a local smoke test, use this Collector configuration and point the services
at its HTTP receiver. The debug exporter writes received telemetry to the
collector's logs; replace it with your backend exporter for deployment.

```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
processors:
  batch: {}
exporters:
  debug:
    verbosity: basic
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug]
```

The checked-in Compose example uses this configuration. To test the source
instrumentation (in the private source checkout), run
`go test -race ./internal/telemetry ./internal/audit`; tests cover propagation,
sampling-independent audit correlation, export shutdown, metrics, redaction,
streaming and HTTP upgrade handling.

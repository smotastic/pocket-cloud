# observability

Shared metrics stack: Prometheus receives metrics from every service over OTLP
and scrapes per-container CPU and memory from cAdvisor; Grafana shows them.
Metrics only; there are no traces or logs (no Tempo, no Loki).

| | |
|---|---|
| Grafana | http://localhost:3001 (`GRAFANA_HTTP_PORT`), user `admin` |
| Prometheus UI | http://localhost:9090 (`PROMETHEUS_PORT`) |
| OTLP metrics | `http://prometheus:9090/api/v1/otlp/v1/metrics` (OTLP/HTTP only, no gRPC) |
| Data | `${DATA_ROOT}/observability/grafana` (Grafana DB), `${DATA_ROOT}/observability/prometheus` (TSDB) |

Idle memory is about 0.8 GiB together, nearly all of it Grafana.

## First run

1. Set `GRAFANA_ADMIN_PASSWORD` in `.env`. Grafana only applies it when it creates
   its database on the first start; later changes to `.env` have no effect, change
   the password in the UI (or delete `grafana.db` to start over).
2. `mkdir -p "$DATA_ROOT"/observability/{grafana,prometheus}`, then
   `docker compose up -d prometheus grafana` from the repo root.

Anonymous access is off. The Prometheus data source and the dashboards are
provisioned from [`grafana/provisioning/`](grafana/provisioning/) and can't be
edited in the UI.

## Dashboards

Every `*.json` in [`grafana/provisioning/dashboards/`](grafana/provisioning/dashboards/)
appears in the *pocket-cloud* folder; Grafana rescans it every 60 s. To change one,
edit a copy in the UI (*Save as*), export it as JSON and replace the file.

| Dashboard | Shows |
|---|---|
| Container memory | Working set per app and per container, memory limits, OOM kills, VM total |

An *app* is the container name up to the first dash, two words for `pocket-*`:
`bookmarks-server` → `bookmarks`, `pocket-galaxy-web` → `pocket-galaxy`. New stacks
show up without changes as long as their containers follow that naming.

## Container metrics (cAdvisor)

cAdvisor runs privileged with read-only mounts of the Colima VM's `/`, `/sys` and
`/var/lib/docker`, so it sees the VM (8 GiB), not the Mac. Prometheus scrapes it at
`cadvisor:8080` (not published). Only CPU, memory and OOM metrics are collected, and
the only container label kept is `com.docker.compose.service`, to keep cardinality low.
Memory panels use `container_memory_working_set_bytes`, the same number `docker stats`
shows.

## Sending metrics from a service

A service in this compose project reaches Prometheus by service name. In its
`stacks/<service>/compose.yaml`:

```yaml
    environment:
      OTEL_EXPORTER_OTLP_METRICS_ENDPOINT: http://prometheus:9090/api/v1/otlp/v1/metrics
      OTEL_SERVICE_NAME: bookmarks
      OTEL_RESOURCE_ATTRIBUTES: service.version=${BOOKMARKS_VERSION},deployment.environment.name=production
```

Use the same value for `service.version` as for the image tag, so they can't drift.
Only metrics can be sent. A base `OTEL_EXPORTER_OTLP_ENDPOINT` would also send
traces and logs to `/api/v1/otlp/v1/traces` and `/v1/logs`, which return 404.
The exact variables a service reads are defined by the service (for pocket-factory
see smotastic/pocket-factory#4).

[`prometheus.yml`](prometheus.yml) turns `service.name`, `service.version` and
`deployment.environment.name` into the labels `service_name`, `service_version`
and `deployment_environment_name`. `service.name` also becomes `job`.

Retention is 30 days or 5 GB, whichever is hit first. The TSDB is excluded from
the restic backup; Grafana's DB is backed up.

## Smoke test

Push a few test metrics and query them back:

```sh
docker run --rm --network pocket-cloud_default \
  ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.162.0 metrics \
  --otlp-http --otlp-insecure --otlp-endpoint prometheus:9090 \
  --otlp-http-url-path /api/v1/otlp/v1/metrics \
  --metrics 5 --service smoke-test \
  --otlp-attributes 'service.version="0.0.1"' \
  --otlp-attributes 'deployment.environment.name="production"'
```

In Grafana, *Explore* → `{job="smoke-test"}` shows the metric `gen` with the labels
above.

## Access

Grafana and Prometheus are published on all interfaces of the Mac, so any device
on the LAN can reach them. Nothing is reachable from outside because the router
forwards no ports. The Prometheus UI and query API have no authentication;
revisit this before exposing the Mac via Tailscale.

## Debugging

```sh
docker compose logs -f prometheus      # OTLP ingest errors show up here
docker compose logs -f grafana         # dashboard provisioning errors show up here
docker compose logs -f cadvisor
```

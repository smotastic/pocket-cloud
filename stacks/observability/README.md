# observability

Shared metrics and logs stack: Prometheus receives metrics from every service over
OTLP and scrapes per-container CPU and memory from cAdvisor and Gitea's own
metrics. Loki stores logs: Alloy tails the output of every container, and services
can also push logs over OTLP. Grafana shows both. There are no traces (no Tempo).
Alertmanager sends Prometheus alerts to Discord; so far they watch the Colima VM's
disks and the Mac's own disk (see [Alerts](#alerts)).

| | |
|---|---|
| Grafana | http://localhost:3001 (`GRAFANA_HTTP_PORT`), user `admin` |
| Prometheus UI | http://localhost:9090 (`PROMETHEUS_PORT`) |
| Alertmanager UI | http://localhost:9093 (`ALERTMANAGER_PORT`), active alerts and silences |
| OTLP metrics | `http://prometheus:9090/api/v1/otlp/v1/metrics` (OTLP/HTTP only, no gRPC) |
| OTLP logs | `http://loki:3100/otlp/v1/logs` (OTLP/HTTP only, inside the compose network) |
| Data | `${DATA_ROOT}/observability/grafana` (Grafana DB), `.../prometheus` (TSDB), `.../loki` (logs), `.../alloy` (read positions), `.../alertmanager` (silences) |

Idle memory is about 1 GiB together, most of it Grafana; Loki and Alloy add
about 250 MiB.

## First run

1. Set `GRAFANA_ADMIN_PASSWORD` in `.env`. Grafana only applies it when it creates
   its database on the first start; later changes to `.env` have no effect, change
   the password in the UI (or delete `grafana.db` to start over).
2. `mkdir -p "$DATA_ROOT"/observability/{grafana,prometheus,loki,alloy,alertmanager}`, then
   `docker compose up -d prometheus node-exporter alertmanager loki alloy grafana` from the repo root.

On its first start Alloy ships every container's existing log history. Loki
rejects lines older than 7 days (`timestamp too old`) and rate-limits the rest
for a minute or two; both errors stop once Alloy has caught up.

Anonymous access is off. The Prometheus and Loki data sources and the dashboards are
provisioned from [`grafana/provisioning/`](grafana/provisioning/) and can't be
edited in the UI.

## Dashboards

Every `*.json` in [`grafana/provisioning/dashboards/`](grafana/provisioning/dashboards/)
appears in the *pocket-cloud* folder; Grafana rescans it every 60 s. To change one,
edit a copy in the UI (*Save as*), export it as JSON and replace the file.

| Dashboard | Shows |
|---|---|
| Container memory | Working set per app and per container, memory limits, OOM kills, VM total |
| Gitea | Scrape status, repositories, open and closed issues, process memory |

Apps ship their own dashboards: those live in
[`grafana/dashboards/<app>/`](grafana/dashboards/), each folder with a provider in
`grafana/provisioning/dashboards/<app>.yaml` that shows it in a Grafana folder of the same
name. They are copied from the app's release tag and replaced on an upgrade, not edited here.

| Folder | Dashboard | Source |
|---|---|---|
| pocket-home | Ingestor (`pocket-home-ingestor`) | pocket-home `apps/home-server/observability/grafana/dashboards/ingestor.json`, see [`../pocket-home/README.md`](../pocket-home/README.md#observability) |

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

## Gitea metrics

Prometheus scrapes `gitea:3000/metrics` (job `gitea`) over the compose network with
the bearer token `GITEA_METRICS_TOKEN` from `.env`. Gitea checks the same variable,
see [`../gitea/README.md`](../gitea/README.md#metrics). Prometheus' config can't read
environment variables, so [`compose.yaml`](compose.yaml) mounts the token as the file
`/etc/prometheus/gitea-metrics-token`. Gitea's metrics are counts from its database
(repositories, issues, users, ...) plus Go runtime and process metrics.

Check the target under *Status* → *Target health* in the Prometheus UI, or:

```sh
curl -s 'http://localhost:9090/api/v1/targets?scrapePool=gitea' | grep -o '"health":"[a-z]*"'
```

`"health":"up"` is good. A `401 Unauthorized` error means the two containers have
different tokens: recreate both
(`docker compose up -d --force-recreate gitea prometheus`).

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

## Logs (Loki and Alloy)

[`config.alloy`](config.alloy) discovers every container in the Colima VM through the
Docker socket (mounted read-only) and pushes its stdout and stderr to Loki. New stacks
are picked up without changes. Each stream has two labels:

| Label | From |
|---|---|
| `container` | container name, e.g. `bookmarks-server` |
| `service_name` | compose service, e.g. `bookmarks-server` |

In Grafana, *Explore* → *Loki* → `{container="gitea"} |= "error"`. Loki indexes only
the labels; the text after `|=` is searched line by line, which is fast enough at this
volume. Grafana adds `detected_level` from the log line where it can.

[`loki.yaml`](loki.yaml) runs Loki as a single binary with its index and chunks on the
filesystem. Retention is 30 days, enforced by the compactor; there is no size limit.
Loki is not published on the Mac, it has no authentication.

### Sending logs from a service

Writing to stdout is enough; Alloy collects it. A service that wants structured
logs with resource attributes can push them over OTLP instead:

```yaml
    environment:
      OTEL_EXPORTER_OTLP_LOGS_ENDPOINT: http://loki:3100/otlp/v1/logs
```

together with the `OTEL_SERVICE_NAME` and `OTEL_RESOURCE_ATTRIBUTES` from the
metrics section. Loki turns `service.name` and `deployment.environment.name` into
labels and keeps the other attributes as structured metadata. Such a service
should not also log the same lines to stdout, or every line is stored twice
(once with `container`, once without).

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

The same for logs:

```sh
docker run --rm --network pocket-cloud_default \
  ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.162.0 logs \
  --otlp-http --otlp-insecure --otlp-endpoint loki:3100 \
  --otlp-http-url-path /otlp/v1/logs \
  --logs 3 --service smoke-test \
  --otlp-attributes 'deployment.environment.name="production"'
```

*Explore* → *Loki* → `{service_name="smoke-test"}` shows three lines `the message`.

## Alerts

Prometheus evaluates the rules in [`alerts.yml`](alerts.yml) every 30 s and hands firing
alerts to Alertmanager, which sends them to one Discord channel
([`alertmanager.yml`](alertmanager.yml)). Resolved alerts are sent too; an alert that
keeps firing is repeated every 12 h.

| Alert | Fires when |
|---|---|
| `VmDiskFilling` (warning) | a Colima VM disk (`/` or `/var/lib/docker`) is over 80 % full for 10 min |
| `VmDiskAlmostFull` (critical) | the same disk is over 90 % full for 5 min; replaces the warning |
| `MacDiskFilling` (warning) | the Mac's disk that holds `${DATA_ROOT}` is over 80 % full for 10 min |
| `MacDiskAlmostFull` (critical) | the same disk is over 90 % full for 5 min; replaces the warning |
| `MacDiskMetricsMissing` (warning) | no disk metrics from the Mac for 10 min |
| `ScrapeTargetDown` (warning) | node-exporter, cAdvisor or Alertmanager can't be scraped for 5 min |

The VM's disk numbers come from node-exporter, which reads the VM's filesystems through a
read-only mount of its `/`. `/var/lib/docker` is the VM's data disk with images,
containers and build cache. They count ext4's reserved blocks as used, so they read a
few percent higher than `df`.

### Grafana-managed alerts

Apps that ship Grafana alert rules get them provisioned from
[`grafana/provisioning/alerting/`](grafana/provisioning/alerting/), so far pocket-home's
ingestor (`ingestor.yaml`, rule group `ingestor` in the folder `pocket-home`, see
[`../pocket-home/README.md`](../pocket-home/README.md#observability)). Grafana evaluates them
itself, not Prometheus, and sends them through
[`contact-points.yaml`](grafana/provisioning/alerting/contact-points.yaml) to the same Discord
webhook, read from the compose secret. That file replaces Grafana's whole notification policy
tree; rules and contact points can't be edited in the UI. After a change,
`docker compose up -d --force-recreate grafana`. They are under *Alerting* → *Alert rules*.

### The Mac's disk

`${DATA_ROOT}` is on the Mac, not in the VM. Inside the VM it is only the virtiofs mount,
which reports a meaningless size (about 254 TB), so node-exporter can't watch it. Instead
the launchd agent `dev.pocket-cloud.disk-metrics` runs
[`scripts/disk-metrics.sh`](../../scripts/disk-metrics.sh) every minute: it reads
`df -kP "$DATA_ROOT"` and pushes two gauges over OTLP to `127.0.0.1:${PROMETHEUS_PORT}`,
with the job `mac-disk` and the label `mountpoint` (`/System/Volumes/Data`):

| Metric | Meaning |
|---|---|
| `mac_filesystem_size_bytes` | size of the APFS container, shared by all its volumes |
| `mac_filesystem_avail_bytes` | free space in it |

Used is `1 - avail / size`, which also counts the other volumes (system, snapshots), so it
reads a little higher than `df`'s *Capacity*. A push instead of a native node-exporter keeps
the Mac free of another listening port and binary to pin; the price is that a stopped agent
looks like no data, hence `MacDiskMetricsMissing`.

```sh
scripts/install-disk-metrics.sh            # push once, then every minute from login on
scripts/install-disk-metrics.sh status     # agent state and the end of the log
scripts/install-disk-metrics.sh run-now    # push once, in this shell
```

It needs Prometheus running and only `DATA_ROOT` and `PROMETHEUS_PORT` from `.env`, read on
every run. Errors go to `~/Library/Logs/pocket-cloud/disk-metrics.log`; the log stays empty
while all is well. A run while the VM is down fails and is retried a minute later.

### Set up the Discord webhook

1. In Discord, create a channel for alerts on a server where you can manage webhooks
   (your own server works), e.g. `#pocket-cloud-alerts`.
2. *Edit Channel* (gear icon) → *Integrations* → *Webhooks* → *New Webhook*. Name it,
   e.g. `pocket-cloud`, and *Copy Webhook URL*.
3. Put the URL into `ALERTS_DISCORD_WEBHOOK_URL` in `.env`. It is a secret: anyone with
   it can post to the channel. If it leaks, delete the webhook and create a new one.
4. `docker compose up -d --force-recreate alertmanager grafana`. Compose writes the value to
   `/run/secrets/` when it creates the container, so a changed `.env` needs a recreate.
5. So that alerts reach your phone: in the Discord app, long-press the channel →
   *Notification Settings* → *All Messages*, and don't mute the channel or server.

Without the URL, alerts still show up in Prometheus (*Alerts*) and in the
Alertmanager UI, and Alertmanager logs `Notify for alerts failed`.

Send a test alert, which arrives within 30 s and resolves after 5 min:

```sh
curl -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestAlert","severity":"warning"},"annotations":{"summary":"test"}}]'
```

To mute an alert, for example during planned work, create a silence in the
Alertmanager UI.

### Changing rules

Edit `alerts.yml` and check it before reloading:

```sh
docker run --rm -v "$PWD"/stacks/observability:/c:ro --entrypoint promtool \
  prom/prometheus:v3.15.0 check rules /c/alerts.yml
docker compose restart prometheus
```

Use `amtool check-config` from the `prom/alertmanager` image the same way for
`alertmanager.yml`, then `docker compose restart alertmanager`.

## Access

Grafana, Prometheus and Alertmanager are published on all interfaces of the Mac, so
any device on the LAN can reach them. Nothing is reachable from outside because the
router forwards no ports. The Prometheus and Alertmanager UIs and APIs have no
authentication (anyone on the LAN could silence an alert); revisit this before
exposing the Mac via Tailscale.

## Debugging

```sh
docker compose logs -f prometheus      # OTLP ingest errors show up here
docker compose logs -f grafana         # dashboard provisioning errors show up here
docker compose logs -f cadvisor
docker compose logs -f alertmanager    # failed Discord sends show up here
docker compose logs -f loki            # rejected pushes (too old, rate limit) show up here
docker compose logs -f alloy
```

# bookmarks

Proof-of-concept own app: the bookmarks blueprint from
[pocket-factory](https://github.com/smotastic/pocket-factory) (`blueprints/bookmarks`).
Its images are built by Gitea Actions and pulled from Gitea's container registry.

| | |
|---|---|
| Web app | http://localhost:3002 (`BOOKMARKS_HTTP_PORT`) |
| API docs | http://localhost:3002/docs |
| Version | `BOOKMARKS_VERSION` in `.env`, the image tag of both images |
| Data | `${DATA_ROOT}/bookmarks/postgres` (PostgreSQL data directory) |

| Service | Image | Role |
|---|---|---|
| `bookmarks-web` | `bookmarks-web` | nginx: serves the web app, proxies `/api`, `/docs`, `/health` to the server. The only published port. |
| `bookmarks-server` | `bookmarks-server` | REST API on port 3000, internal only |
| `bookmarks-migrate` | `bookmarks-server` | Runs the database migrations on every `up`, then exits. The server starts only after it succeeds. |
| `bookmarks-postgres` | `postgres` | Database, internal only |

## First run

1. Log the pocket-cloud Docker daemon in to Gitea's registry once
   (see [`../gitea/README.md`](../gitea/README.md#container-registry)).
2. Set `BOOKMARKS_DB_PASSWORD` and `BOOKMARKS_VERSION` in `.env`. Postgres only
   applies the password when it initialises an empty data directory; to change it
   later, run `ALTER USER bookmarks PASSWORD '...'` in `psql`, then update `.env`.
3. `mkdir -p "$DATA_ROOT"/bookmarks/postgres`, then
   `docker compose up -d bookmarks-web` from the repo root (pulls in its dependencies).

## Updating

A release in pocket-factory is a git tag `bookmarks-vX.Y.Z`, which builds and pushes
both images as `X.Y.Z`. To deploy it, set `BOOKMARKS_VERSION=X.Y.Z` in `.env` and run:

```sh
docker compose up -d bookmarks-web
```

Migrations run before the new server starts. They are idempotent, so rerunning them
on every `up` is safe.

`BOOKMARKS_VERSION` lives in `.env`, not in `compose.yaml`, because it also feeds
`service.version` for metrics; it can't drift from the image tag.

## Metrics

The server pushes metrics over OTLP to Prometheus (`OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`,
see [`../observability/README.md`](../observability/README.md)). Traces and logs
stay off: no endpoint is set for them. In Grafana, `{job="bookmarks"}` shows
`http_server_request_duration_seconds` per route, with the labels `service_version`
and `deployment_environment_name`.

## Backup

`scripts/backup.sh` stops `bookmarks-server` and `bookmarks-postgres` while the
snapshot is taken, so the data directory is consistent.
The web app is unavailable for those few seconds.

## Access

The app has **no authentication**. Only `bookmarks-web` is published, on all
interfaces of the Mac, so any device on the LAN can read and change bookmarks.
Nothing is reachable from outside because the router forwards no ports. Revisit
before exposing the Mac via Tailscale.

## Debugging

```sh
docker compose logs bookmarks-migrate         # migration output of the last `up`
docker compose logs -f bookmarks-server
docker compose exec bookmarks-postgres psql -U bookmarks
```

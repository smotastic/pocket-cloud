# pocket-galaxy

[Pocket Galaxy](https://github.com/smotastic/pocket-galaxy): worlds, lore entries and
maps for tabletop campaigns, as an installable web app (PWA) with a REST API and the
`pocket` CLI. Its images are built by Gitea Actions on a release tag and pulled from
Gitea's container registry. This stack replaces the old Raspberry Pi deployment; no data
moved from the Pi, the stack started empty.

| | |
|---|---|
| Web app | https://galaxy.\<tailnet\>.ts.net (tailnet, HTTPS, installable), http://\<mac-name\>.local:3004 (LAN, `POCKET_GALAXY_HTTP_PORT`) |
| API docs | https://galaxy.\<tailnet\>.ts.net/docs |
| Version | `POCKET_GALAXY_VERSION` in `.env`, the image tag of both images |
| Data | `${DATA_ROOT}/pocket-galaxy/postgres` (PostgreSQL data directory), `${DATA_ROOT}/pocket-galaxy/assets` (uploaded images and their variants) |

| Service | Image | Role |
|---|---|---|
| `pocket-galaxy-web` | `pocket-galaxy-web` | nginx: serves the PWA, proxies `/api`, `/docs`, `/health` to the server, caps uploads at 50 MB. The only published port. |
| `pocket-galaxy-server` | `pocket-galaxy-server` | REST API on port 3000, internal only. Writes the asset files to `/data/assets` (`ASSET_DIR`). Limited to 1 GiB of memory: sharp decodes uploaded maps in memory. |
| `pocket-galaxy-migrate` | `pocket-galaxy-server` | Runs the migrations of every module on every `up`, then exits. The server starts only after it succeeds. |
| `pocket-galaxy-postgres` | `postgres` | Database, one schema per module (`worlds`, `entries`, `assets`, `scenes`). Internal only. |

## First run

1. Log the pocket-cloud Docker daemon in to Gitea's registry once
   (see [`../gitea/README.md`](../gitea/README.md#container-registry)).
2. In `.env`, set `POCKET_GALAXY_VERSION` (e.g. `0.1.0`) and generate
   `POCKET_GALAXY_DB_PASSWORD` with `openssl rand -hex 32`. It goes into `DATABASE_URL`,
   so it must only contain URL-safe characters. Postgres only applies the password when it
   initialises an empty data directory; to change it later, run
   `ALTER USER "pocket-galaxy" PASSWORD '...'` in `psql`, then update `.env`.
3. Create the data folders:

   ```sh
   source .env && mkdir -p "$DATA_ROOT"/pocket-galaxy/{postgres,assets}
   ```

   No `chown` is needed: the server runs as uid 1000 (`node`), and Colima's virtiofs mount
   lets it write the asset folder although the folder belongs to your user on the Mac.

4. `docker compose up -d pocket-galaxy-web` from the repo root (pulls in its dependencies).
   The server is ready once `docker compose ps` shows it `healthy`; its readiness check
   asks the database and writes a probe file to the asset folder.
5. For HTTPS over the tailnet, start its Tailscale node `tailscale-galaxy`
   (see [`../tailscale/README.md`](../tailscale/README.md#first-start)).

## Updating

A release in pocket-galaxy is a git tag `pocket-galaxy-vX.Y.Z`, which builds and pushes
both images as `X.Y.Z`. To deploy it, set `POCKET_GALAXY_VERSION=X.Y.Z` in `.env` and run:

```sh
docker compose up -d pocket-galaxy-web
```

Migrations run before the new server starts. Each module keeps its own migration history,
so rerunning them on every `up` is safe.

`POCKET_GALAXY_VERSION` lives in `.env`, not in `compose.yaml`, because it also feeds
`service.version` for metrics; it can't drift from the image tag.

### Rollback

Set `POCKET_GALAXY_VERSION` back to the previous version and run the same `up -d`.
Migrations are usually additive (new tables and columns only), so the older server runs on
the newer schema; the older migrate step finds nothing to do. A release whose migration isn't
additive says so in its tag message, and rolling back means restoring the backup taken before
the update. Take that backup first:

```sh
B="$DATA_ROOT/backups/pocket-galaxy-<old version>-$(date +%Y%m%d-%H%M%S)" && mkdir -p "$B"
docker compose exec -T pocket-galaxy-postgres pg_dump -U pocket-galaxy -d pocket-galaxy -Fc > "$B/pocket-galaxy.dump"
tar -C "$DATA_ROOT/pocket-galaxy" -czf "$B/assets.tar.gz" assets
```

**0.4.0** (page tree, spec 014) is not additive: it moves the parent scene into the page tree
and drops `scenes.map_facets.parent_entry_id`. Its `/api/v1` changes are breaking, so install
the `pocket` CLI from the same release.

## The `pocket` CLI

The CLI reads the worlds and entries over the API, for people and coding agents. Install
it from a pocket-galaxy checkout and point it at this stack once:

```sh
pnpm cli:install
pocket use --url https://galaxy.<tailnet>.ts.net
pocket worlds
```

## Lore import

The old lore import (pocket-galaxy tag `lore-import-final`) targets the API before 0.4.0 and
never ran against this stack. The import of the tyria-codex content into 0.4.0 and later,
rules included, is pocket-galaxy spec 015; its runbook replaces this section.

## Metrics

The server pushes metrics over OTLP to Prometheus (`OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`,
see [`../observability/README.md`](../observability/README.md)). Traces and logs
stay off: no endpoint is set for them. In Grafana, `{job="pocket-galaxy"}` shows
`http_server_request_duration_seconds` per route, with the labels `service_version`
and `deployment_environment_name`.

## Backup

`scripts/backup.sh` stops `pocket-galaxy-server` and `pocket-galaxy-postgres` while the
snapshot is taken, so the database matches the asset files next to it. The app is
unavailable for those few seconds. `scripts/backup.sh restore-test` starts a throwaway
Postgres on the restored data directory and logs the number of worlds, entries and asset
files.

## Access

The app has **no authentication** (pocket-galaxy ADR 0016: reachable only from the home
network or the tailnet). Two ways in:

- **Tailnet**: `https://galaxy.<tailnet>.ts.net`, served by its own Tailscale node
  `tailscale-galaxy` with a Tailscale certificate (see
  [`../tailscale/README.md`](../tailscale/README.md)). Every member of the tailnet can read
  and change every world. No Funnel, so it is not reachable from the internet. Use this address everywhere: the
  PWA's service worker needs HTTPS, so only here can the app be installed (Add to Home
  Screen / Install app) and get its offline shell.
- **LAN**: `pocket-galaxy-web` is also published on `POCKET_GALAXY_HTTP_PORT`, on all
  interfaces of the Mac, over plain HTTP. Any device on the LAN (and, with Tailscale's
  default policy, on the tailnet via the Mac's address) can use it, but not install it.
  The router forwards no ports.

## Debugging

```sh
docker compose logs pocket-galaxy-migrate          # migration output of the last `up`
docker compose logs -f pocket-galaxy-server
docker compose exec pocket-galaxy-postgres psql -U pocket-galaxy
docker compose exec pocket-galaxy-server ls -ln /data/assets   # owner must be 1000
```

A server that stays unhealthy while the database is up usually can't write
`${DATA_ROOT}/pocket-galaxy/assets` (the readiness check writes a probe file there);
check its owner. A container killed with exit code
137 hit the memory limit, typically while decoding a very large map.

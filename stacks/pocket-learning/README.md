# pocket-learning

[pocket-learning](https://github.com/smotastic/pocket-learning): flashcards with spaced review,
starting with Tulu. A web app for review, a REST API and the `learn` CLI the teaching agent uses
to write cards. Its images are built from the repository's Dockerfiles and pulled from Gitea's
container registry.

| | |
|---|---|
| Web app | https://learning.\<tailnet\>.ts.net (tailnet, HTTPS), http://\<mac-name\>.local:3006 (LAN, `POCKET_LEARNING_HTTP_PORT`) |
| API docs | https://learning.\<tailnet\>.ts.net/docs |
| Version | `POCKET_LEARNING_VERSION` in `.env`, the image tag of both images |
| Data | `${DATA_ROOT}/pocket-learning/postgres` (PostgreSQL data directory) |

| Service | Image | Role |
|---|---|---|
| `pocket-learning-web` | `learning-web` | nginx: serves the web app, proxies `/api`, `/docs`, `/health` to the server. The only published port. |
| `pocket-learning-server` | `learning-server` | REST API on port 3000, internal only. |
| `pocket-learning-migrate` | `learning-server` | Runs the migrations on every `up`, then exits. The server starts only after it succeeds. |
| `pocket-learning-postgres` | `postgres` | Database, schema `learning`. Internal only. |

## First run

1. Log the pocket-cloud Docker daemon in to Gitea's registry once
   (see [`../gitea/README.md`](../gitea/README.md#container-registry)).
2. In `.env`, set `POCKET_LEARNING_VERSION` (e.g. `0.1.0`) and generate
   `POCKET_LEARNING_DB_PASSWORD` with `openssl rand -hex 32`. It goes into `DATABASE_URL`,
   so it must only contain URL-safe characters. Postgres only applies the password when it
   initialises an empty data directory; to change it later, run
   `ALTER USER "pocket-learning" PASSWORD '...'` in `psql`, then update `.env`.
3. Create the data folder:

   ```sh
   source .env && mkdir -p "$DATA_ROOT"/pocket-learning/postgres
   ```

4. `docker compose up -d pocket-learning-web` from the repo root (pulls in its dependencies).
   The server is ready once `docker compose ps` shows it `healthy`.
5. For HTTPS over the tailnet, start its Tailscale node `tailscale-learning`
   (see [`../tailscale/README.md`](../tailscale/README.md#first-start)).
6. Import the old flashcards once, see [below](#flashcards-import).

## Updating

A release in pocket-learning is a git tag `learning-vX.Y.Z`, which builds and pushes both
images as `X.Y.Z`. To deploy it, set `POCKET_LEARNING_VERSION=X.Y.Z` in `.env` and run:

```sh
docker compose up -d pocket-learning-web
```

Migrations run before the new server starts; rerunning them on every `up` is safe.

### Rollback

Set `POCKET_LEARNING_VERSION` back to the previous version and run the same `up -d`. This
works as long as migrations are additive; otherwise restore the backup taken before the update.

## Flashcards import

The cards, reviews and flags of the old flashcards app (`deck/items.jsonl`,
`data/reviews.jsonl`, `data/flags.jsonl`) are imported once, after the first `up`. Run the
importer as a one-shot container from the server image, with the old folder mounted read-only
(it must be below `$HOME`, which Colima mounts):

```sh
source .env && docker compose run --rm --no-deps \
  -v <flashcards folder>:/import:ro \
  pocket-learning-migrate node --enable-source-maps dist/import.js /import
```

Running it again adds nothing.

## The `learn` CLI

The teaching agent writes cards through the CLI. Install it from a pocket-learning checkout and
point it at this stack:

```sh
export LEARNING_API_URL=https://learning.<tailnet>.ts.net
```

## Metrics

The server pushes metrics over OTLP to Prometheus (`OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`,
see [`../observability/README.md`](../observability/README.md)). Traces and logs stay off. In
Grafana, `{job="pocket-learning"}` shows `http_server_request_duration_seconds` per route.

## Backup

`scripts/backup.sh` stops `pocket-learning-server` and `pocket-learning-postgres` while the
snapshot is taken. `scripts/backup.sh restore-test` starts a throwaway Postgres on the restored
data directory and logs the number of cards and reviews.

## Access

The app has **no authentication** (accounts are out of scope in pocket-learning's spec 004):
reachable only from the home network or the tailnet. Anyone who can reach it can review, and
anyone who can reach `/api/v1/teacher` can change cards.

- **Tailnet**: `https://learning.<tailnet>.ts.net`, served by its own Tailscale node
  `tailscale-learning`. No Funnel.
- **LAN**: `pocket-learning-web` is also published on `POCKET_LEARNING_HTTP_PORT` over plain
  HTTP. The router forwards no ports.

## Debugging

```sh
docker compose logs pocket-learning-migrate        # migration output of the last `up`
docker compose logs -f pocket-learning-server
docker compose exec pocket-learning-postgres psql -U pocket-learning
```

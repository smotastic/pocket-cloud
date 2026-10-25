# pocket-home

[pocket-home](https://github.com/smotastic/pocket-home): the home's Shelly BLU devices.
A Shelly BLU Gateway publishes the Door/Window sensors and TRVs it hears to the MQTT
broker; the ingestor subscribes, stores their history in PostgreSQL, sets TRV targets,
runs window setback rules and sends Telegram notifications; the home web app is its UI.
The images are built by Gitea Actions on a release tag and pulled from Gitea's container
registry. The deploy contract is in pocket-home's
[ingestor README](https://github.com/smotastic/pocket-home/blob/master/apps/ingestor-server/README.md#deploy-contract-pocket-cloud)
and [home-web README](https://github.com/smotastic/pocket-home/blob/master/apps/home-web/README.md#deploy-contract).

| | |
|---|---|
| Web app | http://\<mac-name\>.local:3005 (LAN, `POCKET_HOME_HTTP_PORT`) |
| API docs | http://\<mac-name\>.local:3005/docs |
| MQTT | `<mac-name>.local:1883` (`POCKET_HOME_MQTT_PORT`), plain TCP, LAN only |
| Versions | `POCKET_HOME_INGESTOR_VERSION`, `POCKET_HOME_WEB_VERSION` in `.env`; the two images are released apart |
| Data | `${DATA_ROOT}/pocket-home/mosquitto/{config,data}` (generated `passwd`, `mosquitto.db`), `${DATA_ROOT}/pocket-home/postgres` (PostgreSQL data directory) |

| Service | Image | Role |
|---|---|---|
| `pocket-home-mosquitto` | `eclipse-mosquitto` | MQTT broker, port 1883 published for the gateway. Config in [`mosquitto.conf`](mosquitto.conf), mounted read-only. |
| `pocket-home-web` | `home-web` | nginx: serves the web app, proxies `/api`, `/docs`, `/health` to the ingestor. The only published HTTP port. |
| `pocket-home-ingestor` | `ingestor` | API on port 3000, internal only, and the MQTT subscriber. One instance only: the broker keeps its session under one client id. |
| `pocket-home-migrate` | `ingestor` | Runs the migrations on every `up`, then exits. The ingestor starts only after it succeeds. |
| `pocket-home-postgres` | `postgres` | Database, schema `ingestor`. Internal only. |

## Before the first release

Only the broker runs today. Everything else is in the compose profile `pocket-home`, so a
plain `docker compose up -d` leaves it out while the images don't exist yet. Once
`ingestor-v*` and `home-web-v*` are released, remove the `profiles:` lines from
[`compose.yaml`](compose.yaml). To try a release before that, add `--profile pocket-home`
to the commands below.

## Broker users

Anonymous access is off. There are two users, both set in `.env`:

| Variables | Used by |
|---|---|
| `POCKET_HOME_MQTT_GATEWAY_USER`, `POCKET_HOME_MQTT_GATEWAY_PASSWORD` | Shelly BLU Gateway |
| `POCKET_HOME_MQTT_INGESTOR_USER`, `POCKET_HOME_MQTT_INGESTOR_PASSWORD` | `pocket-home-ingestor` |

The broker's entrypoint (see [`compose.yaml`](compose.yaml)) deletes
`${DATA_ROOT}/pocket-home/mosquitto/config/passwd` and rebuilds it on every start with
`mosquitto_passwd -b` from these variables, then starts the broker. The file holds salted
hashes only. To add, rename or change a user, edit `.env` and run
`docker compose up -d pocket-home-mosquitto`; don't edit `passwd` by hand, it's
overwritten. The ingestor gets its user and password from the same variables.

There is no ACL yet: both users may read and write every topic. The per-user rules are in
the ingestor's deploy contract.

## First run

1. Log the pocket-cloud Docker daemon in to Gitea's registry once
   (see [`../gitea/README.md`](../gitea/README.md#container-registry)).
2. In `.env`:
   - choose the two broker user names and generate their passwords with
     `openssl rand -hex 24`;
   - set `POCKET_HOME_INGESTOR_VERSION` and `POCKET_HOME_WEB_VERSION` (e.g. `0.1.0`);
   - generate `POCKET_HOME_DB_PASSWORD` with `openssl rand -hex 32`. It goes into
     `DATABASE_URL`, so it must only contain URL-safe characters. Postgres only applies it
     when it initialises an empty data directory;
   - generate `POCKET_HOME_API_TOKEN` with `openssl rand -base64 32` and keep it in the
     password manager: it signs in the web app and authorises every API call;
   - optionally `POCKET_HOME_TELEGRAM_BOT_TOKEN` and `POCKET_HOME_TELEGRAM_CHAT_ID` (both
     or neither, see the ingestor README, "Set up the bot") and
     `POCKET_HOME_HISTORY_RETENTION_DAYS` (irreversible, unset keeps everything).
3. Create the data folders:

   ```sh
   source .env && mkdir -p "$DATA_ROOT"/pocket-home/{mosquitto/config,mosquitto/data,postgres}
   ```

4. `docker compose up -d pocket-home-web` from the repo root (pulls in its dependencies).
   The ingestor is ready once `docker compose ps` shows it `healthy`; its readiness check
   asks the database and the broker connection.
5. Connect the gateway (next section) and open the web app.

Test the broker from the Mac (needs `brew install mosquitto` for the clients):

```sh
mosquitto_sub -h localhost -u "$POCKET_HOME_MQTT_INGESTOR_USER" -P "$POCKET_HOME_MQTT_INGESTOR_PASSWORD" -t '#' -v
```

## Shelly BLU Gateway

Use pocket-home's `provision-gateway` command (ingestor README, "Set up the gateway") with
`mqtt.server: <mac-name>.local:1883` (or the Mac's LAN IP if the gateway can't resolve
`.local`) and the gateway user; the password comes from
`POCKET_HOME_MQTT_GATEWAY_PASSWORD`. No TLS yet (smotastic/pocket-home#41).

## Persistence

`persistence true` writes retained messages, subscriptions and queued messages to
`mosquitto.db` every 60 s and on shutdown. The ingestor connects with a fixed client ID
and a persistent session, so it keeps its QoS 1 messages across a broker restart.
Sessions of clients gone for more than 14 days are dropped.

## Updating

A release in pocket-home is a git tag `ingestor-vX.Y.Z` or `home-web-vX.Y.Z`, which pushes
that image as `X.Y.Z`. Read the ingestor README's "Before upgrading" notes first, set the
version in `.env` and run:

```sh
docker compose up -d pocket-home-web
```

Migrations run before the new ingestor starts; running them twice changes nothing.

The broker: change its tag in `compose.yaml`, then `docker compose up -d pocket-home-mosquitto`.
Release notes: https://mosquitto.org/blog/

## Observability

The ingestor sends metrics to Prometheus over OTLP under the job `ingestor-server`. Its
Grafana dashboard and alert rules ship with each release (`observability/grafana/` in
pocket-home); provisioning them here is open.

## Backup

`scripts/backup.sh` stops the broker, the ingestor and Postgres during the snapshot, so
`mosquitto.db` is flushed and the Postgres data directory is consistent.

## Debugging

```sh
docker compose logs -f pocket-home-mosquitto pocket-home-ingestor
```

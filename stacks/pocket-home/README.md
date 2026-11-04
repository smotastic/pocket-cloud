# pocket-home

[pocket-home](https://github.com/smotastic/pocket-home): the home's Shelly BLU devices.
A Shelly BLU Gateway publishes the Door/Window sensors and TRVs it hears to the MQTT
broker; the ingestor (in pocket-home's `home-server` app) subscribes, stores their history in PostgreSQL, sets TRV targets,
runs its automations and notifies through Discord; the home web app is its UI.
The images are built by Gitea Actions on a release tag and pulled from Gitea's container
registry. The deploy contract is in pocket-home's
[home-server README](https://github.com/smotastic/pocket-home/blob/master/apps/home-server/README.md#deploy-contract-pocket-cloud)
and [home-web README](https://github.com/smotastic/pocket-home/blob/master/apps/home-web/README.md#deploy-contract).

| | |
|---|---|
| Web app | http://\<mac-name\>.local:3005 (LAN, `POCKET_HOME_HTTP_PORT`), https://home.\<tailnet\>.ts.net (tailnet) |
| API docs | http://\<mac-name\>.local:3005/docs |
| MQTT | `<mac-name>.local:1883` (`POCKET_HOME_MQTT_PORT`), plain TCP, and `<mac-name>.local:8883` (`POCKET_HOME_MQTTS_PORT`), TLS; LAN only |
| Versions | `POCKET_HOME_SERVER_VERSION`, `POCKET_HOME_WEB_VERSION` in `.env`; the two images are released apart |
| Data | `${DATA_ROOT}/pocket-home/mosquitto/{config,data}` (generated `passwd` and `acl`, `certs/`, `mosquitto.db`), `${DATA_ROOT}/pocket-home/mqtt-ca` (the broker's CA and its key), `${DATA_ROOT}/pocket-home/postgres` (PostgreSQL data directory) |

| Service | Image | Role |
|---|---|---|
| `pocket-home-mosquitto` | `eclipse-mosquitto` | MQTT broker, ports 1883 and 8883 (TLS) published for the gateway. Config in [`mosquitto.conf`](mosquitto.conf), mounted read-only. |
| `pocket-home-web` | `home-web` | nginx: serves the web app, proxies `/api`, `/docs`, `/health` to the ingestor. The only published HTTP port. |
| `pocket-home-ingestor` | `home-server` | API on port 3000, internal only, and the MQTT subscriber. One instance only: the broker keeps its session under one client id. |
| `pocket-home-migrate` | `home-server` | Runs the migrations on every `up`, then exits. The ingestor starts only after it succeeds. |
| `pocket-home-postgres` | `postgres` | Database, schema `ingestor`. Internal only. |

## Broker users

Anonymous access is off. There are two users, both set in `.env`:

| Variables | Used by |
|---|---|
| `POCKET_HOME_MQTT_GATEWAY_USER`, `POCKET_HOME_MQTT_GATEWAY_PASSWORD` | Shelly BLU Gateway |
| `POCKET_HOME_MQTT_INGESTOR_USER`, `POCKET_HOME_MQTT_INGESTOR_PASSWORD` | `pocket-home-ingestor` |

The broker's entrypoint (see [`compose.yaml`](compose.yaml)) deletes
`${DATA_ROOT}/pocket-home/mosquitto/config/passwd` and rebuilds it on every start with
`mosquitto_passwd -b` from these variables, then writes the ACL `acl` next to it and starts
the broker. The password file holds salted hashes only. To add, rename or change a user, edit
`.env` and run `docker compose up -d pocket-home-mosquitto`; don't edit `passwd` or `acl` by
hand, they're overwritten. The ingestor gets its user and password from the same variables.

### ACL

Each user may use only its own topics, as in the ingestor's deploy contract. `<prefix>` is
`POCKET_HOME_MQTT_GATEWAY_TOPIC_PREFIX`, the gateway's topic prefix (by default its device id,
`shellyblugwg3-<mac>`); the ingestor's client id is its default, `pocket-home-ingestor`.

| User | Publish | Subscribe |
|---|---|---|
| gateway | `<prefix>/#`, `pocket-home-ingestor-rpc/rpc` (answers to the ingestor's calls) | `<prefix>/#` |
| ingestor | `<prefix>/rpc` (`Shelly.GetComponents`, `BluTrv.Call`) | `+/events/rpc`, `+/online`, `pocket-home-ingestor-rpc/rpc` |

Mosquitto checks a subscription's filter against the rules as written, so the ingestor's
filters stay the wildcards `+/events/rpc` and `+/online`; a refused subscription keeps it not
ready. Anything else is dropped: a publish outside these topics is discarded and a
subscription to `#` receives nothing. A new gateway, or one with another prefix, needs the
prefix changed in `.env` and a broker restart.

## First run

1. Log the pocket-cloud Docker daemon in to Gitea's registry once
   (see [`../gitea/README.md`](../gitea/README.md#container-registry)).
2. In `.env`:
   - choose the two broker user names and generate their passwords with
     `openssl rand -hex 24`, and set `POCKET_HOME_MQTT_GATEWAY_TOPIC_PREFIX` (see
     [ACL](#acl));
   - set `POCKET_HOME_SERVER_VERSION` and `POCKET_HOME_WEB_VERSION` (e.g. `0.2.0`);
   - generate `POCKET_HOME_DB_PASSWORD` with `openssl rand -hex 32`. It goes into
     `DATABASE_URL`, so it must only contain URL-safe characters. Postgres only applies it
     when it initialises an empty data directory;
   - generate `POCKET_HOME_API_TOKEN` with `openssl rand -base64 32` and keep it in the
     password manager: it signs in the web app and authorises every API call;
   - optionally `POCKET_HOME_NOTIFICATION_WEBHOOK`, the Discord webhook URL that automations
     notify (see the home-server README, "Set up the webhooks"). Failed automations go to
     `ALERTS_DISCORD_WEBHOOK_URL`, the channel of the Grafana alerts;
   - `POCKET_HOME_HISTORY_RETENTION_DAYS`: `730` keeps two heating seasons (the ingestor
     README's suggestion). Deleting is irreversible; take a database backup before lowering
     it. Empty keeps everything.
3. Create the data folders and the broker's certificates (see [TLS](#tls)):

   ```sh
   source .env && mkdir -p "$DATA_ROOT"/pocket-home/{mosquitto/config,mosquitto/data,postgres}
   scripts/pocket-home-mqtt-certs.sh
   ```

4. `docker compose up -d pocket-home-web` from the repo root (pulls in its dependencies).
   The ingestor is ready once `docker compose ps` shows it `healthy`; its readiness check
   asks the database and the broker connection.
5. Connect the gateway (next section) and open the web app.

Test the broker from the Mac (needs `brew install mosquitto` for the clients); the ACL lets
the ingestor user read the gateway's notifications and online status:

```sh
mosquitto_sub -h localhost -u "$POCKET_HOME_MQTT_INGESTOR_USER" -P "$POCKET_HOME_MQTT_INGESTOR_PASSWORD" -t '+/events/rpc' -t '+/online' -v
```

Over TLS, with the CA:

```sh
mosquitto_sub -h localhost -p 8883 --cafile "$DATA_ROOT"/pocket-home/mqtt-ca/ca.crt \
  -u "$POCKET_HOME_MQTT_INGESTOR_USER" -P "$POCKET_HOME_MQTT_INGESTOR_PASSWORD" -t '+/online' -v
```

Check the API with the token (`401` without it):

```sh
curl -H "Authorization: Bearer $POCKET_HOME_API_TOKEN" "http://localhost:$POCKET_HOME_HTTP_PORT/api/v1/devices"
```

## Shelly BLU Gateway

Use pocket-home's `provision-gateway` command (ingestor README, "Set up the gateway") with
`mqtt.server: <mac-name>.local:1883` (or the Mac's LAN IP if the gateway can't resolve
`.local`) and the gateway user; the password comes from
`POCKET_HOME_MQTT_GATEWAY_PASSWORD`. The gateway stays on plain TCP (1883) until it is
switched to TLS and checked on the real hardware (smotastic/pocket-home#42); then it uses
`mqtt.server: <mac-name>.local:8883` and `mqtt.tls.ca` with a copy of
`${DATA_ROOT}/pocket-home/mqtt-ca/ca.crt`.

## TLS

The broker listens on 8883 with a certificate from its own CA, next to plain 1883. The
ingestor connects over TLS (`mqtts://pocket-home-mosquitto:8883`) and checks the certificate
against the CA (`MQTT_TLS_CA_FILE`); it logs `MQTT over TLS` at the start. Clients log in with
the same users and ACL; there are no client certificates.

[`scripts/pocket-home-mqtt-certs.sh`](../../scripts/pocket-home-mqtt-certs.sh) creates both on
the Mac with `openssl`:

| File | Where | Mounted |
|---|---|---|
| CA key and certificate (10 years) | `${DATA_ROOT}/pocket-home/mqtt-ca/` | no; the key never enters a container |
| Broker key and certificate (825 days), CA certificate | `${DATA_ROOT}/pocket-home/mosquitto/config/certs/` | broker; the CA certificate also into the ingestor |

The broker certificate names `pocket-home-mosquitto` (the ingestor), `localhost`, and the
Mac's `.local` name and LAN address at the time it is issued (the gateway). The broker
refuses to start without the files.

```sh
scripts/pocket-home-mqtt-certs.sh status          # names and expiry dates
scripts/pocket-home-mqtt-certs.sh renew [name...]  # new broker certificate, same CA; extra names optional
docker compose up -d --force-recreate pocket-home-mosquitto
```

Renew before the broker certificate expires, and when the Mac's LAN address or name changes.
The CA stays; clients that trust it need no change. Closing the plain listener is for after
the gateway is on TLS (smotastic/pocket-home#42).

## Remote access

The tailnet reaches the web app at `https://home.<tailnet>.ts.net` through the sidecar
`tailscale-home` (see [`../tailscale/README.md`](../tailscale/README.md)); nothing else of
pocket-home is in the tailnet beyond the Mac's LAN ports (see Hardening there). Signing in
works on both: `API_COOKIE_SECURE` stays `false` because the LAN port is plain HTTP, and the
cookie is still `HttpOnly` and `SameSite=Strict`.

## Persistence

`persistence true` writes retained messages, subscriptions and queued messages to
`mosquitto.db` every 60 s and on shutdown. The ingestor connects with a fixed client ID
and a persistent session, so it keeps its QoS 1 messages across a broker restart.
Sessions of clients gone for more than 14 days are dropped.

## Updating

A release in pocket-home is a git tag `home-server-vX.Y.Z` or `home-web-vX.Y.Z`, which pushes
that image as `X.Y.Z`. Read the home-server README's "Before upgrading" notes first. For a
home-server release, copy its dashboard and alert rules from the same tag (see
[Observability](#observability)). Set the version in `.env` and run:

```sh
docker compose up -d pocket-home-web
```

Migrations run before the new ingestor starts; running them twice changes nothing.

**From `ingestor-v0.1.0`.** pocket-home renamed its server app to `home-server` (its ADR 0017):
releases up to `ingestor-v0.1.0` are the image `ingestor`, later ones the image `home-server`.
On the first `home-server-vX.Y.Z` upgrade, rename `POCKET_HOME_INGESTOR_VERSION` in `.env` to
`POCKET_HOME_SERVER_VERSION` and set it to the new version. The metrics' `job` changes from
`ingestor-server` to `home-server`; the dashboard's job variable picks it up, and the alert rules
do not filter by job.

The broker: change its tag in `compose.yaml`, then `docker compose up -d pocket-home-mosquitto`.
Release notes: https://mosquitto.org/blog/

## Observability

The ingestor sends metrics to Prometheus over OTLP under the job `home-server` (`ingestor-server`
up to `ingestor-v0.1.0`). Its Grafana dashboard and alert rules ship with each release
(`apps/home-server/observability/grafana/`
in pocket-home) and are provisioned from copies in the observability stack:

| pocket-home file | Copied to |
|---|---|
| `dashboards/ingestor.json` | [`../observability/grafana/dashboards/pocket-home/ingestor.json`](../observability/grafana/dashboards/pocket-home/ingestor.json) |
| `alerting/ingestor.yaml` | [`../observability/grafana/provisioning/alerting/ingestor.yaml`](../observability/grafana/provisioning/alerting/ingestor.yaml) |

They are from `home-server-v0.3.0`. On a home-server upgrade, copy both from the new tag, so the
dashboard queries the metrics that image exports, and run
`docker compose up -d --force-recreate grafana`. The dashboard is *Dashboards* → *pocket-home*
→ *Ingestor*; the five rules (battery low, device stale, gateway offline, MQTT disconnected,
ingestion rejects) are in the folder `pocket-home` and notify the Discord channel of the other
alerts (see [`../observability/README.md`](../observability/README.md#grafana-managed-alerts)).

## Backup

`scripts/backup.sh` stops the broker, the ingestor and Postgres during the snapshot, so
`mosquitto.db` is flushed and the Postgres data directory is consistent.

## Debugging

```sh
docker compose logs -f pocket-home-mosquitto pocket-home-ingestor
```

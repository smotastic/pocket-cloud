# mosquitto

MQTT broker ([Eclipse Mosquitto](https://mosquitto.org)) for
[pocket-home](https://github.com/smotastic/pocket-home): the Shelly BLU Gateway
publishes sensor readings, pocket-home's ingestor subscribes to them.

| | |
|---|---|
| MQTT | `<mac-name>.local:1883` (`MOSQUITTO_PORT`), plain TCP, LAN only |
| Config | [`mosquitto.conf`](mosquitto.conf), mounted read-only from this repo |
| Data | `${DATA_ROOT}/mosquitto/config` (generated `passwd`), `${DATA_ROOT}/mosquitto/data` (`mosquitto.db`, persistence) |

## Users

Anonymous access is off. There are two users, both set in `.env`:

| Variables | Used by |
|---|---|
| `MOSQUITTO_GATEWAY_USER`, `MOSQUITTO_GATEWAY_PASSWORD` | Shelly BLU Gateway |
| `MOSQUITTO_INGESTOR_USER`, `MOSQUITTO_INGESTOR_PASSWORD` | pocket-home ingestor |

### How the password file is created

The container's entrypoint (see [`compose.yaml`](compose.yaml)) deletes
`${DATA_ROOT}/mosquitto/config/passwd` and rebuilds it on every start with
`mosquitto_passwd -b` from these variables, then starts the broker. The file holds
salted hashes only. To add, rename or change a user, edit `.env` and run
`docker compose up -d mosquitto`; don't edit `passwd` by hand, it's overwritten.

## First run

1. In `.env`, choose the two user names and generate the passwords with
   `openssl rand -hex 24`.
2. `source .env && mkdir -p "$DATA_ROOT"/mosquitto/{config,data}`, then
   `docker compose up -d mosquitto` from the repo root.
3. Test from the Mac (needs `brew install mosquitto` for the clients):

   ```sh
   mosquitto_sub -h localhost -u "$MOSQUITTO_INGESTOR_USER" -P "$MOSQUITTO_INGESTOR_PASSWORD" -t '#' -v
   ```

## Shelly BLU Gateway

In the gateway's web UI, *Settings → MQTT*: enable, server `<mac-name>.local:1883`
(or the Mac's LAN IP if the gateway can't resolve `.local`), the gateway user and
password, no TLS.

## Persistence

`persistence true` writes retained messages, subscriptions and queued messages to
`mosquitto.db` every 60 s and on shutdown. A client connecting with a fixed client ID
and `clean_session=false` (MQTT 5: session expiry > 0) keeps its QoS 1 messages
across a broker restart. Sessions of clients gone for more than 14 days are dropped.

## Backup

`scripts/backup.sh` stops `mosquitto` during the snapshot, so `mosquitto.db` is
flushed and consistent.

## Updating

Change the tag in `compose.yaml`, then `docker compose up -d mosquitto`.
Release notes: https://mosquitto.org/blog/

## Debugging

```sh
docker compose logs -f mosquitto
```

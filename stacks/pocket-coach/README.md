# pocket-coach

[pocket-coach](https://github.com/smotastic/pocket-coach): a personal marathon coach. It reads the
owner's Garmin data every 30 minutes through Garmin's official Personal API, keeps a training plan
up to race day, and has a coach agent that details and adapts the next days, writes a morning
briefing and answers in a chat. Its images are built by Gitea Actions and pulled from Gitea's
container registry.

| | |
|---|---|
| Web app | https://coach.\<tailnet\>.ts.net (tailnet, HTTPS), http://\<mac-name\>.local:3007 (LAN, `POCKET_COACH_HTTP_PORT`) |
| API docs | https://coach.\<tailnet\>.ts.net/docs |
| Version | `POCKET_COACH_VERSION` in `.env`, the image tag of both images |
| Data | `${DATA_ROOT}/pocket-coach/postgres` (PostgreSQL), `${DATA_ROOT}/pocket-coach/files` (Garmin's activity files) |

| Service | Image | Role |
|---|---|---|
| `pocket-coach-web` | `pocket-coach-web` | nginx: the web app (an installable PWA that reloads itself onto a new version), proxies `/api`, `/docs`, `/health`. The only published port. |
| `pocket-coach-server` | `pocket-coach-server` | API, Garmin sync and the coach's daily jobs, internal only. Calls the model with the owner's Pi login and the [whisper](../whisper/README.md) stack for voice messages. |
| `pocket-coach-migrate` | `pocket-coach-server` | Runs the migrations on every `up`, then exits. The server starts only after it succeeds. |
| `pocket-coach-postgres` | `postgres` | Database, schema `coach`. Internal only. |

The image names carry the `pocket-` prefix because pocket-learning already owns `coach-server`.

## First run

1. Log the pocket-cloud Docker daemon in to Gitea's registry once
   (see [`../gitea/README.md`](../gitea/README.md#container-registry)).
2. In `.env`, set `POCKET_COACH_VERSION` (e.g. `0.1.0`) and generate the secrets:
   `POCKET_COACH_DB_PASSWORD` with `openssl rand -hex 32` (URL-safe, it goes into `DATABASE_URL`)
   and `POCKET_COACH_SECRET_KEY` with `openssl rand -base64 32`. The secret seals the Garmin key in
   the database; **losing it means entering the Garmin key again**, so keep it with the other
   secrets. Set the model like the learning coach's (`POCKET_COACH_PROVIDER`, `POCKET_COACH_MODEL`,
   `POCKET_COACH_PI_AGENT_DIR`; the same Pi login works for both). Optionally
   `POCKET_COACH_DISCORD_WEBHOOK` for the morning message and the key reminders.
3. Create the data folders:

   ```sh
   source .env && mkdir -p "$DATA_ROOT"/pocket-coach/{postgres,files}
   ```

4. `docker compose up -d pocket-coach-web` from the repo root (pulls in its dependencies).
5. For HTTPS over the tailnet, start its Tailscale node `tailscale-coach`
   (see [`../tailscale/README.md`](../tailscale/README.md#first-start)).
6. Open the app and go through the setup: profile, races, and the Garmin key.

## The Garmin key

Create it in Garmin Connect on the web: **Settings → Personal API Key** (valid for 30 days to one
year), and paste it with its expiry date into the app's setup or Settings. The server checks it
with Garmin, seals it and never shows it again. Fourteen days and one day before it expires, the
coach sends a Discord message; then create a new key and save it in Settings. History (up to two
years) is imported in the background after the first key.

## Updating

A release in pocket-coach is a git tag `coach-vX.Y.Z`, which builds and pushes both images as
`X.Y.Z`. To deploy it, set `POCKET_COACH_VERSION=X.Y.Z` in `.env` and run:

```sh
docker compose up -d pocket-coach-web
```

Migrations run before the new server starts. Installed apps load the new version the next time
they come to the foreground.

### Rollback

Set `POCKET_COACH_VERSION` back and run the same `up -d`. Migrations are forward-only; a rollback
over a migration needs the backup.

## Debugging

```sh
docker compose logs -f pocket-coach-server
docker compose exec pocket-coach-server node -e "fetch('http://localhost:3000/health').then(r => r.text()).then(console.log)"
```

The server refuses to start without the model settings or with a malformed
`POCKET_COACH_SECRET_KEY`, and says which setting is wrong.

# docmost

Household wiki: [Docmost](https://docmost.com), a Notion-like editor for pages
(blocks, `/` commands, tables, draw.io/Excalidraw/Mermaid diagrams, live co-editing,
Markdown export). Chosen over BookStack, AFFiNE, Outline, AppFlowy and SiYuan in #13.

| | |
|---|---|
| Web UI | https://docmost.\<tailnet\>.ts.net (tailnet, HTTPS), http://\<mac-name\>.local:3003 (LAN, `DOCMOST_HTTP_PORT`) |
| Data | `${DATA_ROOT}/docmost/storage` (uploads), `${DATA_ROOT}/docmost/postgres` (PostgreSQL data directory) |

| Service | Image | Role |
|---|---|---|
| `docmost` | `docmost/docmost` | App and API. The only published port. |
| `docmost-postgres` | `postgres` | Pages, users, workspace. Internal only. |
| `docmost-redis` | `redis` | Collaboration state and job queues. In memory only, no data on disk. |

Idle memory is about 0.5–0.8 GiB together.

## First run

1. In `.env`, set `DOCMOST_APP_URL` to the address phones open
   (`http://$(scutil --get LocalHostName).local:3003`), and generate
   `DOCMOST_APP_SECRET` and `DOCMOST_DB_PASSWORD` with `openssl rand -hex 32`.
   Postgres only applies the password when it initialises an empty data directory;
   to change it later, run `ALTER USER docmost PASSWORD '...'` in `psql`, then update `.env`.
2. `mkdir -p "$DATA_ROOT"/docmost/{storage,postgres}`, then
   `docker compose up -d docmost` from the repo root (pulls in its dependencies).
3. Open the web UI. The first visit asks for a workspace name and creates the
   admin account. Afterwards sign-up is by invite only.

## Inviting people

No mail server is configured, so invites aren't emailed. Invite the person under
*Settings → Members*, then copy the link from the pending invite and send it by
messenger.

Do this over HTTPS, at `https://docmost.<tailnet>.ts.net`, or on the Mac mini at
`http://localhost:3003`: browsers only allow clipboard access over HTTPS or on
`localhost`, so the copy buttons (invites, page links, code blocks) silently do nothing
at the `.local` address.

Invite links point to `DOCMOST_APP_URL`. Set it to the tailnet address only if everyone
who uses the wiki is in the tailnet; otherwise keep the `.local` address.

Without mail there is no "forgot password" either. Store the passwords in a password manager.

## Phone

There is no native app. Open the URL in the phone's browser and add it to the home
screen. Use `https://docmost.<tailnet>.ts.net` on devices in the tailnet: it works from
anywhere and over HTTPS. It is served by the Tailscale node `tailscale-docmost`, see
[`../tailscale/README.md`](../tailscale/README.md). The `.local` address works on the
home Wi-Fi only.

## Backup

`scripts/backup.sh` stops `docmost` and `docmost-postgres` while the snapshot is
taken, so the database and the uploads match. The data directory is only usable with
the same Postgres major version; before bumping it, dump and reload:

```sh
docker compose exec docmost-postgres pg_dump -U docmost docmost > docmost.sql
```

`scripts/backup.sh restore-test` starts a throwaway Postgres on the restored data
directory and counts the pages.

## Updating

Change the tag in `compose.yaml`, then `docker compose up -d docmost`. Docmost runs
its database migrations on start. Read the release notes first:
https://github.com/docmost/docmost/releases

## Debugging

```sh
docker compose logs -f docmost
docker compose exec docmost-postgres psql -U docmost
```

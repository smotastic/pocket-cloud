# gitea

Self-hosted Git server, using the rootless image and SQLite.

| | |
|---|---|
| Web UI | http://localhost:3000 (`GITEA_HTTP_PORT`) |
| SSH clone | `ssh://git@localhost:2222/<owner>/<repo>.git` (`GITEA_SSH_PORT`) |
| Data | `${DATA_ROOT}/gitea/data` (repos, SQLite DB, attachments) |
| Config | `${DATA_ROOT}/gitea/config/app.ini` |

## First run

1. `docker compose up -d gitea` from the repo root.
2. Open the web UI. The install page is pre-filled from the environment in
   `compose.yaml`. Leave the database on SQLite.
3. Under *Administrator Account Settings*, create your admin user. Public
   registration is disabled, so this is the only way in.
4. Click *Install Gitea*. The result is written to `config/app.ini`.

Settings set via `GITEA__section__KEY` environment variables in `compose.yaml`
override `app.ini` on every start, so keep durable changes there.

## SSH access

Add to `~/.ssh/config` so plain `git@localhost:` URLs work without the port:

```text
Host gitea
  HostName localhost
  Port 2222
  User git
```

Then clone with `git clone gitea:<owner>/<repo>.git`.

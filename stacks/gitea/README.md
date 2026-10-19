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
   `compose.yaml`. Leave the database on SQLite with the default path
   `/var/lib/gitea/data/gitea.db` (a container path; it lands in
   `${DATA_ROOT}/gitea/data/data/`).
3. Under *Administrator Account Settings*, create your admin user. Public
   registration is disabled, so this is the only way in.
4. Click *Install Gitea*. The result is written to `config/app.ini`.
5. The installer leaves `SECRET_KEY` empty, which makes Gitea fall back to a
   publicly known default. Set one before enabling 2FA or Actions secrets:

   ```sh
   docker exec gitea gitea generate secret SECRET_KEY
   # paste into [security] SECRET_KEY in config/app.ini, then:
   docker compose restart gitea
   ```

Settings set via `GITEA__section__KEY` environment variables in `compose.yaml`
override `app.ini` on every start, so keep durable changes there.

## SSH access

Add a key under *Settings → SSH / GPG Keys*, then add to `~/.ssh/config`
(on other devices, use the Mac's hostname instead of `localhost`):

```text
Host gitea
  HostName localhost
  Port 2222
  User git
  IdentityFile ~/.ssh/<your-gitea-key>
  IdentitiesOnly yes
```

Then clone with `git clone gitea:<owner>/<repo>.git`. `ssh gitea` should greet
you by username.

## Moving a repo in from GitHub

Push-to-create is enabled, so no repo needs to be created in the UI first:

```sh
git remote rename origin github
git remote add origin gitea:<owner>/<repo>.git
git push -u origin main     # creates the repo (private)
git push origin --tags
```

The very first push into a new repo can fail with `Unable to access repository
path` although the repo was created; push again.

Then mirror it back to GitHub: create a fine-grained GitHub token for just that
repo with *Contents: read and write* (plus *Workflows: read and write* if it has
`.github/workflows/`). In Gitea, open the repo's *Settings → Repository → Mirror
Settings → Push Mirror*, enter `https://github.com/<owner>/<repo>.git`, the GitHub
username and the token, and tick *Sync when commits are pushed*. From then on,
push only to Gitea.

Tick *Sync when commits are pushed* before clicking *Add Push Mirror*: an existing
mirror can't be switched to it later (the API only adds, deletes and syncs), so
delete and re-add it. Check with `tea api '/repos/<owner>/<repo>/push_mirrors'`
(`sync_on_commit`), and trigger a sync with `tea api -X POST '/repos/<owner>/<repo>/push_mirrors-sync'`.

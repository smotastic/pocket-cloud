# pocket-cloud

Deployment configuration for the services running on the home Mac mini.

This repository only describes **what runs and how**. It contains no application
source code (own apps live in their own repos and are referenced here by image tag)
and no runtime data (that lives under `DATA_ROOT`, outside this repo).

| Layer | Where |
|---|---|
| Host tooling (Homebrew, Colima, Docker CLI) | [`setup`](https://github.com/smotastic/setup) repo |
| Service definitions | this repo, `stacks/<service>/` |
| Service data | `DATA_ROOT` (default `~/pocket-cloud-data`), not in git, backed up separately |

## Layout

```text
compose.yaml          # entry point, includes every stack
mise.toml             # sets DOCKER_CONTEXT inside this repo
AGENTS.md             # rules for coding agents (CLAUDE.md links here)
launchd/              # launchd agent templates (Colima VM, daily backup)
scripts/              # install-autostart.sh, backup.sh, install-backup.sh
.env.example          # copy to .env; DATA_ROOT, domains, ports
stacks/
  gitea/              # Git hosting
  gitea-runner/       # Gitea Actions runner
  observability/      # Grafana + Prometheus (OTLP metrics)
  bookmarks/          # pocket-factory bookmarks blueprint (proof of concept)
  docmost/            # Docmost household wiki
```

## Prerequisites

Containers run in a Linux VM managed by [Colima](https://github.com/abiosoft/colima)
(installed by the `setup` repo). pocket-cloud uses its own Colima profile,
`pocket-cloud`, separate from the `default` profile used for development, so
stopping or resetting the dev VM never takes the services down.

```sh
scripts/install-autostart.sh          # create the VM and start it at every login
scripts/install-autostart.sh status   # agent and VM state
scripts/install-autostart.sh uninstall
```

The script creates the profile (4 CPUs, 8 GiB RAM, vz + virtiofs) on first run and
installs the launchd agent `dev.pocket-cloud.colima`, which runs
`colima start pocket-cloud --foreground` at login and restarts it if it stops.
Logs go to `~/Library/Logs/pocket-cloud/colima.log`. Run over SSH without a
desktop session, it starts the VM directly; the agent then loads at the next login.

Autostart after a reboot requires a login. With FileVault on, that happens when
the disk is unlocked; use `sudo fdesetup authrestart` for planned restarts.

Colima mounts `$HOME` into the VM, so `DATA_ROOT` must be somewhere below it
(or the Colima mount list has to be extended).

### Docker context

The VM is started with `--activate=false`, so it never becomes the default
Docker context. [`mise.toml`](mise.toml) sets `DOCKER_CONTEXT=colima-pocket-cloud`
whenever a shell is inside this repo (needs `mise activate zsh`, done by the
`setup` repo's `.zshrc`). Trust the file once after cloning:

```sh
mise trust
```

Non-interactive shells (scripts, cron, agents) don't load it; there, use
`export DOCKER_CONTEXT=colima-pocket-cloud` or `mise exec -- docker compose ...`.
All `docker compose` commands below assume the context is set.

## First start

```sh
cp .env.example .env            # adjust if needed
source .env && mkdir -p "$DATA_ROOT"/gitea/{data,config} "$DATA_ROOT"/observability/{grafana,prometheus} \
  "$DATA_ROOT"/docmost/{storage,postgres}
docker compose up -d
```

Then follow the per-stack notes, e.g. [`stacks/gitea/README.md`](stacks/gitea/README.md).

## Git remotes

This repo lives in Gitea (`origin`) and is push-mirrored to GitHub on every push.
Push only to Gitea; see [`stacks/gitea/README.md`](stacks/gitea/README.md).

## Day-to-day

```sh
docker compose ps                    # what is running
docker compose logs -f gitea         # follow one service
docker compose pull && docker compose up -d   # apply image updates after bumping tags
docker compose down                  # stop everything (data stays in DATA_ROOT)
```

## Backups

[`scripts/backup.sh`](scripts/backup.sh) snapshots `DATA_ROOT` with
[restic](https://restic.net) (installed by the `setup` repo). Gitea, the runner and the
Postgres-backed stacks (bookmarks, Docmost) are stopped for the few seconds the
snapshot takes, so the SQLite database matches the git repositories and each
Postgres data directory is consistent. The runner's cache and the Prometheus metrics
are excluded. Old snapshots are pruned to 7 daily, 4 weekly and 12 monthly; the
repository is checked every Sunday.

```sh
# once: set RESTIC_REPOSITORY in .env (e.g. on an external disk), then
scripts/backup.sh init            # creates the password file and the repository
scripts/install-backup.sh         # run daily at 03:30 via launchd

scripts/backup.sh run             # back up now
scripts/backup.sh snapshots       # list snapshots
scripts/backup.sh restore-test    # restore latest to a temp dir, check SQLite, git fsck, Docmost's Postgres
scripts/install-backup.sh status  # agent state and the end of the log
```

The restic password is in `~/.config/pocket-cloud/restic-password`. **Keep a copy
in a password manager**: without it, the backups can't be restored. Logs go to
`~/Library/Logs/pocket-cloud/backup.log`.

To restore everything: `docker compose down`, move `DATA_ROOT` aside, then
`restic restore latest --target /` (restic stores the absolute path), and
`docker compose up -d`.

## Conventions

- One folder per service under `stacks/`, each with its own `compose.yaml`,
  added to the `include:` list in the root `compose.yaml`.
- Images are pinned to an exact version. Updating means changing the tag in a commit.
- Persistent data is always a bind mount under `${DATA_ROOT}/<service>/`, never a
  named Docker volume, so it survives a Colima VM reset and is easy to back up.
- Secrets go in `.env` (git-ignored), never in a committed file.

# pocket-cloud

Deployment configuration for the stacks running on the home server.

This repository only describes **what runs and how**. It contains no application
source code (own apps live in their own repos and are referenced here by image tag)
and no runtime data (that lives under `DATA_ROOT`, outside this repo).

| Layer | Where |
|---|---|
| Home server tooling (Homebrew, Colima, Docker CLI) | [`setup`](https://github.com/smotastic/setup) repo |
| Stack definitions | this repo, `stacks/<stack>/` |
| Data root | `DATA_ROOT` (default `~/pocket-cloud-data`), not in git, backed up separately |

## Layout

```text
compose.yaml          # entry point, includes every stack
mise.toml             # sets DOCKER_CONTEXT inside this repo
AGENTS.md             # rules for coding agents (CLAUDE.md links here)
launchd/              # launchd agent templates (pocket-cloud VM, daily backup, home server disk
                      # metrics, build cache prune, pocket-comms, pocket-lens embedder)
scripts/              # install-autostart.sh, backup.sh, install-backup.sh, disk-metrics.sh,
                      # install-disk-metrics.sh, prune-build-cache.sh, install-build-cache-prune.sh,
                      # install-comms.sh, install-lens.sh, pocket-home-mqtt-certs.sh
native/
  pocket-comms/       # pocket-comms' native part, outside the VM (notes only)
  pocket-lens/        # pocket-lens' native part: the image model and card import (notes only)
.env.example          # copy to .env; DATA_ROOT, domains, ports
stacks/
  gitea/              # Git hosting
  gitea-runner/       # Gitea Actions runner
  observability/      # Grafana + Prometheus (OTLP metrics) + cAdvisor + Loki/Alloy (logs) + alerts
  bookmarks/          # pocket-factory bookmarks blueprint (proof of concept)
  docmost/            # Docmost household wiki
  pocket-galaxy/      # Pocket Galaxy, worlds and maps for tabletop campaigns
  pocket-home/        # pocket-home: Shelly BLU ingestor, web app and MQTT broker
  pocket-learning/    # pocket-learning: flashcards with spaced review
  pocket-coach/       # pocket-coach: marathon coach on Garmin data
  pocket-lens/        # pocket-lens: photo library (the VM part)
  whisper/            # speech-to-text for voice messages (speaches, loopback only)
  tailscale/          # one tailnet node per stack reachable from the tailnet (HTTPS)
```

## Prerequisites

Containers run in the pocket-cloud VM, a Linux VM managed by [Colima](https://github.com/abiosoft/colima)
(installed by the `setup` repo). It is the Colima profile `pocket-cloud`, separate from
the `default` profile of the dev VM, so stopping or resetting the dev VM never takes the
stacks down.

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
source .env && mkdir -p "$DATA_ROOT"/gitea/{data,config} "$DATA_ROOT"/observability/{grafana,prometheus,loki,alloy,alertmanager} \
  "$DATA_ROOT"/docmost/{storage,postgres} "$DATA_ROOT"/pocket-galaxy/{postgres,assets,pi} \
  "$DATA_ROOT"/pocket-home/{mosquitto/config,mosquitto/data,postgres} "$DATA_ROOT"/pocket-learning/postgres \
  "$DATA_ROOT"/pocket-coach/{postgres,files} "$DATA_ROOT"/pocket-lens/{postgres,library} \
  "$DATA_ROOT"/tailscale/{galaxy,docmost,learning,coach,lens,home} "$DATA_ROOT"/whisper/models
docker compose up -d
```

Then follow the per-stack notes, e.g. [`stacks/gitea/README.md`](stacks/gitea/README.md).
`TS_AUTHKEY` and the tailnet policy have to be set up first, see
[`stacks/tailscale/README.md`](stacks/tailscale/README.md).

## Remote access

Stacks get a tailnet name and HTTPS through their own tailnet node in
[`stacks/tailscale`](stacks/tailscale/README.md). The home server itself runs Tailscale for SSH
and serves pocket-comms' native part (see below); pocket-lens' native part is reached only from
the pocket-cloud VM. With Tailscale's default policy the tailnet also reaches the home server's
published LAN ports; the stack's README has a stricter policy that keeps them LAN-only.

## Native parts

A native part is the part of a pocket app that runs directly on the home server, outside the
pocket-cloud VM.

### pocket-comms

[pocket-comms](native/pocket-comms/README.md) reads and drives the Herdr coding agents from the
phone. It needs Herdr's Unix socket and the agents' session files in `$HOME`, which the pocket-cloud
VM can't use, so it runs on the home server under the launchd agent `dev.pocket-cloud.comms`. It
listens on `127.0.0.1` only and trusts the `Tailscale-User-Login` header, so the home server's own
`tailscale serve` is the only way in. A tailnet node in the VM can't reach the home server's
loopback, and listening wider would let anyone on the LAN forge the header.

```sh
# once: set POCKET_COMMS_VERSION, POCKET_COMMS_REPO and COMMS_ALLOWED_LOGIN in .env, then
scripts/install-comms.sh            # clone and build the pinned version under DATA_ROOT, start at login
sudo tailscale serve --bg 4410      # once, by hand: HTTPS on the home server's tailnet name

scripts/install-comms.sh status     # agent, version, probe, tailscale serve, log tail
scripts/install-comms.sh update     # after changing POCKET_COMMS_VERSION (also to roll back)
```

After any other `.env` change, run `install` again. Logs go to `~/Library/Logs/pocket-cloud/comms.log`.

### pocket-lens

[pocket-lens](native/pocket-lens/README.md)' image model needs the Apple GPU, which the pocket-cloud
VM can't use, so its worker runs on the home server under the launchd agent
`dev.pocket-cloud.lens-embedder`, next to the `pocket-lens import` command for camera cards. The
rest of pocket-lens is the stack [`stacks/pocket-lens`](stacks/pocket-lens/README.md).

```sh
scripts/install-lens.sh             # install or switch to POCKET_LENS_VERSION
scripts/install-lens.sh status
```

## Git remotes

This repo lives in Gitea (`origin`) and is push-mirrored to GitHub on every push.
Push only to Gitea; see [`stacks/gitea/README.md`](stacks/gitea/README.md).

## Day-to-day

```sh
docker compose ps                    # what is running
docker compose logs -f gitea         # follow one container
docker compose pull && docker compose up -d   # apply image updates after bumping tags
docker compose down                  # stop everything (data stays in DATA_ROOT)
```

## Home server disk alerts

Alerts for the pocket-cloud VM's disks come from the observability stack on its own. The home
server's disk, which holds `DATA_ROOT`, needs a launchd agent that pushes its free space to Prometheus
every minute (see [`stacks/observability/README.md`](stacks/observability/README.md#the-home-servers-disk)):

```sh
scripts/install-disk-metrics.sh          # once, with the observability stack running
scripts/install-disk-metrics.sh status
```

## Build cache

Gitea Actions builds images in the VM, and their BuildKit cache lands on the VM's data disk
(`/var/lib/docker`). CI can add about 30 GB in three hours, which filled the disk twice.

The Colima profile (`~/.colima/pocket-cloud/colima.yaml`, outside this repo) sets a GC policy:

```yaml
docker:
  builder:
    gc:
      enabled: true
      defaultMaxUsedSpace: 20GB
      defaultMinFreeSpace: 15GB
```

`colima ssh -p pocket-cloud -- sudo docker buildx inspect` shows it loaded, but it doesn't cap
the cache. With the containerd image store, BuildKit marks cache records of intermediate build
stages as shared with an image as long as the stage's base image (e.g. `node`) exists, and GC
skips shared records and doesn't count them
([moby/buildkit#7352](https://github.com/moby/buildkit/issues/7352), fixed in BuildKit master
but not yet in a Docker release). `docker buildx du` shows them as *Shared*. `docker builder prune --max-used-space`
and `--keep-storage` skip them as well; only an age filter frees them.

Until a Docker release has the fix, a launchd agent on the home server prunes by age every 15 minutes:
cache older than 2 h when the data disk is 70 % full or more, otherwise older than 12 h.
Install it from the main checkout, since the agent runs the script from there:

```sh
scripts/install-build-cache-prune.sh           # once
scripts/install-build-cache-prune.sh status    # agent state and the last runs
scripts/install-build-cache-prune.sh run-now   # prune once
```

Logs go to `~/Library/Logs/pocket-cloud/build-cache-prune.log`. Keep the GC policy in the
profile as well: it already caps the private records and will cap the rest once fixed.
The `VmDisk*` alerts in [`stacks/observability`](stacks/observability/README.md#alerts)
fire if the agent stops or can't keep up.

## Backups

[`scripts/backup.sh`](scripts/backup.sh) backs up the data root (`DATA_ROOT`) with
[restic](https://restic.net) (installed by the `setup` repo). Gitea, the runner, the
Postgres-backed stacks (bookmarks, Docmost, Pocket Galaxy, pocket-home, pocket-learning,
pocket-coach, pocket-lens) and pocket-home's MQTT broker are stopped for the few seconds the
backup takes, so the SQLite database matches the git repositories and each
Postgres data directory is consistent. The runner's cache, the Prometheus metrics, the Loki logs,
pocket-lens' preview cache and the native parts' builds are excluded. Old snapshots are pruned to 7 daily, 4 weekly and 12 monthly; the
repository is checked every Sunday.

```sh
# once: set RESTIC_REPOSITORY in .env (e.g. on an external disk), then
scripts/backup.sh init            # creates the password file and the repository
scripts/install-backup.sh         # run daily at 03:30 via launchd

scripts/backup.sh run             # back up now
scripts/backup.sh snapshots       # list snapshots
scripts/backup.sh restore-test    # restore latest to a temp dir, check SQLite, git fsck, Docmost's, Pocket Galaxy's, pocket-learning's and pocket-home's Postgres
scripts/install-backup.sh status  # agent state and the end of the log
```

The restic password is in `~/.config/pocket-cloud/restic-password`. **Keep a copy
in a password manager**: without it, the backups can't be restored. Logs go to
`~/Library/Logs/pocket-cloud/backup.log`.

To restore everything: `docker compose down`, move `DATA_ROOT` aside, then
`restic restore latest --target /` (restic stores the absolute path), and
`docker compose up -d`.

## Conventions

- One folder per stack under `stacks/`, each with its own `compose.yaml`,
  added to the `include:` list in the root `compose.yaml`. The exception is a pocket app's
  native part, which runs on the home server: a template in `launchd/`,
  `scripts/install-<name>.sh` and a note in `native/<name>/README.md`.
- Images are pinned to an exact version. Updating means changing the tag in a commit.
- Persistent data is always a bind mount under `${DATA_ROOT}/<stack>/`, never a
  named Docker volume, so it survives a pocket-cloud VM reset and is easy to back up.
- Secrets go in `.env` (git-ignored), never in a committed file.

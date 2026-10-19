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
.env.example          # copy to .env; DATA_ROOT, domains, ports
stacks/
  gitea/              # Git hosting
BACKLOG.md            # planned services and open tasks
```

## Prerequisites

Containers run in a Linux VM managed by [Colima](https://github.com/abiosoft/colima):

```sh
brew install colima docker docker-compose
colima start --vm-type vz --mount-type virtiofs --cpu 4 --memory 8
```

Colima mounts `$HOME` into the VM, so `DATA_ROOT` must be somewhere below it
(or the Colima mount list has to be extended).

## First start

```sh
cp .env.example .env            # adjust if needed
source .env && mkdir -p "$DATA_ROOT"/gitea/{data,config}
docker compose up -d
```

Then follow the per-stack notes, e.g. [`stacks/gitea/README.md`](stacks/gitea/README.md).

## Day-to-day

```sh
docker compose ps                    # what is running
docker compose logs -f gitea         # follow one service
docker compose pull && docker compose up -d   # apply image updates after bumping tags
docker compose down                  # stop everything (data stays in DATA_ROOT)
```

## Conventions

- One folder per service under `stacks/`, each with its own `compose.yaml`,
  added to the `include:` list in the root `compose.yaml`.
- Images are pinned to an exact version. Updating means changing the tag in a commit.
- Persistent data is always a bind mount under `${DATA_ROOT}/<service>/`, never a
  named Docker volume, so it survives a Colima VM reset and is easy to back up.
- Secrets go in `.env` (git-ignored), never in a committed file.

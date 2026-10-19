# AGENTS.md

Deployment configuration (Docker Compose on a Colima VM) for the services on the home Mac mini.
No application source, no runtime data. See [README.md](README.md). Open tasks are Gitea issues.

## Commands

Every `docker` and `docker compose` call must target the pocket-cloud VM, not the dev VM:

```sh
export DOCKER_CONTEXT=colima-pocket-cloud   # set by mise.toml in interactive shells only
docker compose ps
docker compose up -d
docker compose logs -f <service>
```

Agent shells and scripts do not load `mise.toml`. Set `DOCKER_CONTEXT` explicitly, or run
`mise exec -- docker compose ...`. Scripts in `scripts/` that call Docker must export it themselves.

Never run `colima stop`, `colima delete` or `docker compose down -v` on the `pocket-cloud` profile
without asking; it takes every service down.

## Rules

- This repository is **public**. Never commit secrets, hostnames, IPs, or personal paths.
  Secrets go in `.env` (git-ignored); templates use placeholders.
- One folder per service in `stacks/<service>/` with its own `compose.yaml` and `README.md`,
  listed in the root `compose.yaml`. Pin images to an exact version.
- Persistent data is a bind mount under `${DATA_ROOT}/<service>/`, never a named volume.
- Track tasks as Gitea issues (`tea issues ... --login local --repo smotastic/pocket-cloud`), not in
  Markdown files. Close the issue when the task is done (`Closes #N` in the commit); open one for new work.

## Git

- Commit subjects are conventional commits: `<type>(optional-scope): <description>`, imperative,
  lowercase, no trailing period. Types: `feat` `fix` `refactor` `docs` `ci` `build` `chore`.
  Scope is the stack or area, e.g. `feat(gitea): add actions runner`, `chore(gitea): bump to 28.2.1`.
- `origin` is Gitea. Gitea push-mirrors to GitHub (`github` remote) on every push.
  Push only to `origin`; never push to `github` directly, the mirror overwrites it.
- Never force-push `main` or rewrite pushed history.

# gitea-runner

Gitea Actions runner ([`act_runner`](https://gitea.com/gitea/act_runner)). Each job runs in its
own container on the VM's Docker daemon, from the image its `runs-on` label maps to in
[`config.yaml.tpl`](config.yaml.tpl). The workflows' `actions/*` steps are fetched from GitHub.

| | |
|---|---|
| Config | `config.yaml.tpl`, rendered to `${DATA_ROOT}/gitea-runner/data/config.yaml` at start |
| Registration | `${DATA_ROOT}/gitea-runner/data/.runner` |
| Cache (`actions/cache`) | `${DATA_ROOT}/gitea-runner/data/cache` |

## First run

```sh
docker exec gitea gitea actions generate-runner-token   # put into .env as GITEA_RUNNER_REGISTRATION_TOKEN
source .env && mkdir -p "$DATA_ROOT"/gitea-runner/data
docker compose up -d gitea-runner
```

The runner registers once, instance-wide, and shows up under *Site Administration → Actions →
Runners*. To register it again, delete `.runner` and restart with a fresh token.

## Security

The VM's Docker socket is mounted into the runner and into every job container, so jobs can
start containers (Testcontainers, `docker build`). That also means a job has root on the VM,
and the VM mounts `$HOME`. Run only workflows from your own repositories.

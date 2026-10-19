# gitea-runner config template; @GITEA_DOMAIN@ is filled in from .env at start.
# Only values that differ from the defaults; the full
# reference is `docker run --rm --entrypoint gitea-runner <image> config generate`.
log:
  level: info

runner:
  file: /data/.runner
  capacity: 2
  timeout: 1h
  labels:
    - "ubuntu-latest:docker://docker.gitea.com/runner-images:ubuntu-latest"
    - "ubuntu-24.04:docker://docker.gitea.com/runner-images:ubuntu-24.04"

cache:
  enabled: true
  dir: /data/cache

container:
  # Job containers resolve Gitea's ROOT_URL host (GITEA_DOMAIN) to the VM, where port 3000 is published.
  options: --add-host=@GITEA_DOMAIN@:host-gateway
  # docker_host left empty: the VM's Docker socket is mounted into job containers,
  # so jobs can start containers (Testcontainers, docker build).
  docker_host: ""

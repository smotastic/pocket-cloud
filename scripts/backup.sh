#!/usr/bin/env bash
# Back up DATA_ROOT with restic. Gitea, its runner and the Postgres-backed stacks
# (bookmarks, Docmost, Pocket Galaxy) and Mosquitto are stopped while the snapshot is taken, so the SQLite
# database matches the git repositories and the Postgres data directories are
# consistent with the files next to them.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

set -a
# shellcheck source=/dev/null
source .env
set +a

export DOCKER_CONTEXT=colima-pocket-cloud
export RESTIC_REPOSITORY="${RESTIC_REPOSITORY:-}"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-$HOME/.config/pocket-cloud/restic-password}"

# Stopped for the snapshot and started again afterwards, in this order.
SERVICES=(gitea-runner gitea bookmarks-server bookmarks-postgres docmost docmost-postgres
  pocket-galaxy-server pocket-galaxy-postgres mosquitto)
EXCLUDES=(
  "$DATA_ROOT/gitea-runner/data/cache"
  # Metrics are high-churn and low-value; Grafana's DB next to it is kept.
  "$DATA_ROOT/observability/prometheus"
)
KEEP=(--keep-daily 7 --keep-weekly 4 --keep-monthly 12)
TAG=pocket-cloud

usage() {
  cat <<'USAGE'
Usage: scripts/backup.sh [init|run|snapshots|restore-test]

  init          Create the password file (if missing) and the restic repository
  run           Snapshot DATA_ROOT, then prune old snapshots (default)
  snapshots     List snapshots
  restore-test  Restore the latest snapshot to a temp dir and verify it
USAGE
}

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

require_repository() {
  if [[ -z "$RESTIC_REPOSITORY" ]]; then
    echo "RESTIC_REPOSITORY is not set in .env." >&2
    exit 1
  fi
  # A repository on an external disk: fail clearly when the disk isn't mounted,
  # instead of restic creating the path on the internal disk.
  if [[ "$RESTIC_REPOSITORY" == /Volumes/* ]]; then
    local volume
    volume="/Volumes/$(cut -d/ -f3 <<<"$RESTIC_REPOSITORY")"
    if [[ ! -d "$volume" ]]; then
      echo "Backup disk $volume is not mounted." >&2
      exit 1
    fi
  fi
  if [[ ! -s "$RESTIC_PASSWORD_FILE" ]]; then
    echo "Password file $RESTIC_PASSWORD_FILE is missing. Run scripts/backup.sh init." >&2
    exit 1
  fi
}

init() {
  if [[ ! -s "$RESTIC_PASSWORD_FILE" ]]; then
    mkdir -p "$(dirname "$RESTIC_PASSWORD_FILE")"
    chmod 700 "$(dirname "$RESTIC_PASSWORD_FILE")"
    (umask 077 && openssl rand -base64 32 > "$RESTIC_PASSWORD_FILE")
    echo "Created $RESTIC_PASSWORD_FILE."
    echo "Store its content in your password manager: without it the backups can't be restored."
  fi
  require_repository
  if restic cat config >/dev/null 2>&1; then
    echo "Repository $RESTIC_REPOSITORY already exists."
  else
    restic init
  fi
}

docker_up() {
  docker info >/dev/null 2>&1
}

STOPPED=()

restart_services() {
  if [[ ${#STOPPED[@]} -gt 0 ]]; then
    local reversed=()
    for ((i = ${#STOPPED[@]} - 1; i >= 0; i--)); do reversed+=("${STOPPED[i]}"); done
    log "Starting ${reversed[*]}"
    docker compose start "${reversed[@]}"
    STOPPED=()
  fi
}

run() {
  require_repository
  log "Backup of $DATA_ROOT to $RESTIC_REPOSITORY"

  # With the VM down nothing writes to DATA_ROOT, so there is nothing to stop.
  if docker_up; then
    for service in "${SERVICES[@]}"; do
      if [[ -n "$(docker compose ps --status running -q "$service")" ]]; then
        STOPPED+=("$service")
      fi
    done
  else
    log "Docker on $DOCKER_CONTEXT is not reachable; backing up without stopping services"
  fi
  trap restart_services EXIT

  if [[ ${#STOPPED[@]} -gt 0 ]]; then
    log "Stopping ${STOPPED[*]}"
    docker compose stop "${STOPPED[@]}"
  fi

  local exclude_args=()
  for path in "${EXCLUDES[@]}"; do exclude_args+=(--exclude "$path"); done
  restic backup "$DATA_ROOT" --tag "$TAG" "${exclude_args[@]}"

  restart_services

  log "Pruning old snapshots"
  restic forget --tag "$TAG" --prune "${KEEP[@]}"

  # A full check reads the whole repository; once a week is enough.
  if [[ "$(date +%u)" == 7 ]]; then
    log "Weekly repository check"
    restic check
  fi
  log "Backup done"
}

restore_test() {
  require_repository
  # Below $HOME, which Colima mounts, so a container can start on the restored
  # Postgres data. Global, so the EXIT trap can still see it after the function returns.
  RESTORE_TARGET="$(mktemp -d "$HOME/.pocket-cloud-restore.XXXXXX")"
  trap 'docker rm -f docmost-restore-test pocket-galaxy-restore-test >/dev/null 2>&1; rm -rf "$RESTORE_TARGET"' EXIT
  local target="$RESTORE_TARGET"

  log "Restoring latest snapshot to $target"
  restic restore latest --tag "$TAG" --target "$target"
  local restored="$target$DATA_ROOT"

  local db="$restored/gitea/data/data/gitea.db"
  log "SQLite integrity check: $(sqlite3 -readonly "$db" 'PRAGMA integrity_check;')"

  local repo count=0
  while IFS= read -r repo; do
    git -C "$repo" fsck --no-progress --no-dangling >/dev/null
    count=$((count + 1))
  done < <(find "$restored/gitea/data/git/repositories" -mindepth 2 -maxdepth 2 -type d -name '*.git')
  log "git fsck passed for $count repositories"

  if [[ ! -d "$restored/docmost/storage" ]]; then
    echo "Docmost storage folder missing from the snapshot." >&2
    exit 1
  fi
  # Start a throwaway Postgres (same image as the stack) on the restored data directory.
  local image pages=""
  image="$(sed -n 's/^ *image: *\(postgres:.*\)$/\1/p' stacks/docmost/compose.yaml)"
  docker run -d --name docmost-restore-test \
    -v "$restored/docmost/postgres:/var/lib/postgresql" "$image" >/dev/null
  for _ in {1..30}; do
    pages="$(docker exec docmost-restore-test psql -U docmost -d docmost -tAc 'SELECT count(*) FROM pages' 2>/dev/null)" && break
    sleep 1
  done
  if [[ -z "$pages" ]]; then
    docker logs docmost-restore-test >&2
    echo "Restored Docmost database did not start." >&2
    exit 1
  fi
  log "Docmost database starts, $pages pages"

  if [[ ! -d "$restored/pocket-galaxy/assets" ]]; then
    echo "Pocket Galaxy asset folder missing from the snapshot." >&2
    exit 1
  fi
  # Postgres 17 keeps its data directly in /var/lib/postgresql/data.
  local galaxy_image counts=""
  galaxy_image="$(sed -n 's/^ *image: *\(postgres:.*\)$/\1/p' stacks/pocket-galaxy/compose.yaml)"
  docker run -d --name pocket-galaxy-restore-test \
    -v "$restored/pocket-galaxy/postgres:/var/lib/postgresql/data" "$galaxy_image" >/dev/null
  for _ in {1..30}; do
    counts="$(docker exec pocket-galaxy-restore-test psql -U pocket-galaxy -d pocket-galaxy -tAc \
      "SELECT (SELECT count(*) FROM worlds.worlds) || ' worlds, ' || (SELECT count(*) FROM entries.entries) || ' entries'" \
      2>/dev/null)" && break
    sleep 1
  done
  if [[ -z "$counts" ]]; then
    docker logs pocket-galaxy-restore-test >&2
    echo "Restored Pocket Galaxy database did not start." >&2
    exit 1
  fi
  log "Pocket Galaxy database starts, $counts, $(find "$restored/pocket-galaxy/assets" -type f | wc -l | tr -d ' ') asset files"
  log "Restore test done"
}

case "${1:-run}" in
  init) init ;;
  run) run ;;
  snapshots) require_repository && restic snapshots ;;
  restore-test) restore_test ;;
  -h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac

#!/usr/bin/env bash
# Run pocket-comms natively on the Mac via a launchd agent: check out the pinned
# version under DATA_ROOT, build it, and keep the server running. It needs Herdr's
# socket and the session files in $HOME, so it can't run in the Colima VM.
# See native/pocket-comms/README.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="dev.pocket-cloud.comms"
TEMPLATE="$REPO_ROOT/launchd/$LABEL.plist"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
LOG="$HOME/Library/Logs/pocket-cloud/comms.log"

# Built releases kept on disk, the running one included, for rollback without a build.
KEEP_RELEASES=3
# Marks a release whose install and build finished.
BUILT_MARKER=".pocket-cloud-built"

set -a
# shellcheck source=/dev/null
source "$REPO_ROOT/.env"
set +a

COMMS_DIR="$DATA_ROOT/pocket-comms"
COMMS_PORT="${COMMS_PORT:-4410}"

usage() {
  cat <<'USAGE'
Usage: scripts/install-comms.sh [install|uninstall|status|restart|update]

  install    Build POCKET_COMMS_VERSION if needed, switch to it and register the agent (default)
  update     Fetch new tags first, then install; also how to roll back to an earlier version
  uninstall  Unregister the agent; releases and the tailscale serve config are kept
  status     Show the agent, the running version, the server probe and tailscale serve
  restart    Restart the server
USAGE
}

is_loaded() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

has_gui_domain() {
  launchctl print "$DOMAIN" >/dev/null 2>&1
}

git_repo() {
  git -C "$COMMS_DIR/repo" "$@"
}

major_version() {
  cut -d. -f1 <<<"${1#v}"
}

check_requirements() {
  local tool
  for tool in git node pnpm curl; do
    command -v "$tool" >/dev/null || { echo "$tool not found. Run ./bootstrap.sh brew in the setup repo." >&2; exit 1; }
  done
  if (( $(major_version "$(node --version)") < 26 )); then
    echo "pocket-comms needs Node.js 26+, found $(node --version)." >&2
    exit 1
  fi
  if (( $(major_version "$(pnpm --version)") < 11 )); then
    echo "pocket-comms needs pnpm 11+, found $(pnpm --version)." >&2
    exit 1
  fi

  local name
  for name in POCKET_COMMS_VERSION POCKET_COMMS_REPO COMMS_ALLOWED_LOGIN; do
    [[ -n "${!name:-}" ]] || { echo "$name is not set in .env." >&2; exit 1; }
  done
  # A specific login only; it also goes into the plist unescaped.
  if [[ ! "$COMMS_ALLOWED_LOGIN" =~ ^[A-Za-z0-9._+-]+@[A-Za-z0-9._-]*$ ]]; then
    echo "COMMS_ALLOWED_LOGIN must be a Tailscale login such as <user>@ or <user>@github." >&2
    exit 1
  fi
  if [[ ! "$COMMS_PORT" =~ ^[0-9]+$ ]]; then
    echo "COMMS_PORT must be a port number." >&2
    exit 1
  fi
}

fetch() {
  if [[ ! -d "$COMMS_DIR/repo/.git" ]]; then
    mkdir -p "$COMMS_DIR/releases"
    git clone --no-checkout "$POCKET_COMMS_REPO" "$COMMS_DIR/repo"
  fi
  git_repo fetch --quiet --tags --prune --force origin
}

# Prints the commit POCKET_COMMS_VERSION names. Only tags and full SHAs: a branch
# or a short SHA could name another commit later.
resolve_version() {
  local version="$POCKET_COMMS_VERSION"
  if [[ "$version" =~ ^[0-9a-f]{40}$ ]]; then
    git_repo rev-parse --quiet --verify "$version^{commit}"
  elif git_repo show-ref --quiet --verify "refs/tags/$version"; then
    git_repo rev-parse --verify "refs/tags/$version^{commit}"
  else
    return 1
  fi
}

build_release() {
  local sha="$1" release="$COMMS_DIR/releases/$1"
  [[ -f "$release/$BUILT_MARKER" ]] && return

  # Left over from a failed build.
  if [[ -e "$release" ]]; then
    git_repo worktree remove --force "$release" 2>/dev/null || rm -rf "$release"
    git_repo worktree prune
  fi

  echo "Building pocket-comms $POCKET_COMMS_VERSION ($sha)..."
  git_repo worktree add --quiet --detach "$release" "$sha"
  (
    cd "$release"
    HUSKY=0 pnpm install --frozen-lockfile
    NX_DAEMON=false NX_NO_CLOUD=true pnpm exec nx run-many -t build -p comms-server comms-web
  )
  if [[ ! -f "$release/apps/comms-server/dist/main.js" || ! -f "$release/apps/comms-web/dist/index.html" ]]; then
    echo "The build of $sha did not produce the server and the web app." >&2
    exit 1
  fi
  touch "$release/$BUILT_MARKER"
}

current_sha() {
  local target
  target="$(readlink "$COMMS_DIR/current" 2>/dev/null)" || return 1
  basename "$target"
}

switch_to() {
  ln -sfn "releases/$1" "$COMMS_DIR/current.new"
  mv -fh "$COMMS_DIR/current.new" "$COMMS_DIR/current"
}

render_agent() {
  mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"
  sed -e "s|__NODE__|$(command -v node)|g" \
      -e "s|__COMMS_DIR__|$COMMS_DIR|g" \
      -e "s|__COMMS_PORT__|$COMMS_PORT|g" \
      -e "s|__COMMS_ALLOWED_LOGIN__|$COMMS_ALLOWED_LOGIN|g" \
      -e "s|__BREW_PREFIX__|$(brew --prefix)|g" \
      -e "s|__HOME__|$HOME|g" \
      "$TEMPLATE" > "$AGENT"
  plutil -lint "$AGENT" >/dev/null
}

load_agent() {
  if is_loaded; then
    launchctl bootout "$DOMAIN/$LABEL"
    # bootout returns before the service is gone; bootstrap fails until it is.
    for _ in {1..20}; do
      is_loaded || break
      sleep 0.5
    done
  fi
  launchctl bootstrap "$DOMAIN" "$AGENT"
}

# HTTP status of the server on loopback; 000 when nothing answers.
probe() {
  curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$COMMS_PORT/" || true
}

# Without the Tailscale-User-Login header a running server answers 403. Anything
# else is down, or worse, not checking the login.
wait_for_server() {
  local code
  for _ in {1..20}; do
    code="$(probe)"
    [[ "$code" == 403 ]] && return
    sleep 0.5
  done
  echo "pocket-comms answered $code instead of 403 on 127.0.0.1:$COMMS_PORT; see $LOG." >&2
  return 1
}

prune_releases() {
  local current kept=0 release
  current="$(current_sha || true)"
  # Newest first, by build time.
  while read -r release; do
    [[ "$release" == "$current" ]] && continue
    if (( ++kept < KEEP_RELEASES )); then continue; fi
    git_repo worktree remove --force "$COMMS_DIR/releases/$release" 2>/dev/null \
      || rm -rf "${COMMS_DIR:?}/releases/$release"
  done < <(ls -1t "$COMMS_DIR/releases")
  git_repo worktree prune
}

install() {
  local sha previous

  check_requirements
  if [[ ! -d "$COMMS_DIR/repo/.git" ]] || ! sha="$(resolve_version)"; then
    fetch
  fi
  sha="$(resolve_version)" || {
    echo "POCKET_COMMS_VERSION=$POCKET_COMMS_VERSION is not a tag or a full commit SHA of pocket-comms." >&2
    exit 1
  }

  build_release "$sha"
  previous="$(current_sha || true)"
  switch_to "$sha"
  render_agent

  # Over SSH without a desktop session the gui domain doesn't exist; the agent
  # then loads at the next desktop login, like dev.pocket-cloud.colima.
  if ! has_gui_domain; then
    echo "No desktop session ($DOMAIN); $LABEL will load at the next login."
    return
  fi
  load_agent
  if ! wait_for_server; then
    if [[ -n "$previous" && "$previous" != "$sha" && -d "$COMMS_DIR/releases/$previous" ]]; then
      echo "Rolling back to $previous." >&2
      switch_to "$previous"
      launchctl kickstart -k "$DOMAIN/$LABEL"
    fi
    exit 1
  fi
  prune_releases
  echo "Registered $LABEL, running pocket-comms $POCKET_COMMS_VERSION ($sha) on 127.0.0.1:$COMMS_PORT."
}

update() {
  check_requirements
  fetch
  install
}

uninstall() {
  if is_loaded; then
    launchctl bootout "$DOMAIN/$LABEL"
    echo "Unregistered $LABEL."
  fi
  rm -f "$AGENT"
  echo "Releases in $COMMS_DIR are kept. tailscale serve is left as it is; stop it with: tailscale serve reset"
}

status() {
  local sha tag code

  if is_loaded; then
    # One tab: the service's own lines, not those of its nested endpoints.
    launchctl print "$DOMAIN/$LABEL" | grep -E $'^\t(state|last exit code) ='
  elif [[ -f "$AGENT" ]]; then
    echo "$LABEL is installed and loads at the next desktop login."
  else
    echo "$LABEL is not installed."
  fi

  if sha="$(current_sha)"; then
    tag="$(git_repo describe --tags --exact-match "$sha" 2>/dev/null || echo "untagged")"
    echo "Version: $tag ($sha)"
  fi
  code="$(probe)"
  case "$code" in
    403) echo "Server: up on 127.0.0.1:$COMMS_PORT" ;;
    000) echo "Server: not answering on 127.0.0.1:$COMMS_PORT" ;;
    *) echo "Server: answered $code instead of 403 on 127.0.0.1:$COMMS_PORT" ;;
  esac
  lsof -nP -iTCP:"$COMMS_PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print "Listening: " $9 }' || true

  if command -v tailscale >/dev/null; then
    echo "tailscale serve:"
    tailscale serve status 2>&1 | sed 's/^/  /' || true
  fi
  tail -n 5 "$LOG" 2>/dev/null || true
}

case "${1:-install}" in
  install) install ;;
  update) update ;;
  uninstall) uninstall ;;
  status) status ;;
  restart) launchctl kickstart -k "$DOMAIN/$LABEL" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac

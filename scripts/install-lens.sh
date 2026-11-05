#!/usr/bin/env bash
# The host side of pocket-lens: check out the release lens-v$POCKET_LENS_VERSION under DATA_ROOT,
# build the CLI and the model worker, write the CLI's token file and wrapper, and register the
# socket-activated model worker. The server runs every import in the VM (stacks/pocket-lens) and
# asks the worker for vectors. See native/pocket-lens/README.md.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EMBEDDER_LABEL="dev.pocket-cloud.lens-embedder"
# The agents of lens 0.4 and earlier, which ran the import on the host; removed on install.
RETIRED_LABELS=("dev.pocket-cloud.lens-run" "dev.pocket-cloud.lens-watch")
DOMAIN="gui/$(id -u)"
BUILT_MARKER=".pocket-cloud-built"
KEEP_RELEASES=3

set -a
# shellcheck source=/dev/null
source "$REPO_ROOT/.env"
set +a

LENS_DIR="$DATA_ROOT/pocket-lens/host"
LIBRARY="$DATA_ROOT/pocket-lens/library"
UPLOADS="$DATA_ROOT/pocket-lens/uploads"
TOKEN_FILE="$HOME/.config/pocket-lens/ingest-token"
API_PORT="${POCKET_LENS_API_PORT:-4420}"
EMBEDDER_PORT="${POCKET_LENS_EMBEDDER_PORT:-4421}"

usage() {
  cat <<'USAGE'
Usage: scripts/install-lens.sh [install|update|uninstall|status|run]

  install    Build lens-v$POCKET_LENS_VERSION if needed, switch to it, register the worker (default)
  update     Fetch new tags first, then install
  uninstall  Unregister the worker; releases, the library and the token are kept
  status     Show the worker, the release and the server probe
  run        Ask the server to import the inbox now, as Import now does
USAGE
}

git_repo() { git -C "$LENS_DIR/repo" "$@"; }
is_loaded() { launchctl print "$DOMAIN/$1" >/dev/null 2>&1; }
has_gui_domain() { launchctl print "$DOMAIN" >/dev/null 2>&1; }

check_requirements() {
  local tool name
  for tool in git node pnpm uv curl; do
    command -v "$tool" >/dev/null || { echo "$tool not found (brew install $tool)." >&2; exit 1; }
  done
  for name in POCKET_LENS_VERSION POCKET_LENS_REPO POCKET_LENS_INGEST_TOKEN; do
    [[ -n "${!name:-}" ]] || { echo "$name is not set in .env." >&2; exit 1; }
  done
  [[ "$POCKET_LENS_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "POCKET_LENS_VERSION must be X.Y.Z (the tag lens-vX.Y.Z)." >&2
    exit 1
  }
}

fetch() {
  if [[ ! -d "$LENS_DIR/repo/.git" ]]; then
    mkdir -p "$LENS_DIR/releases"
    git clone --no-checkout "$POCKET_LENS_REPO" "$LENS_DIR/repo"
  fi
  git_repo fetch --quiet --tags --prune --force origin
}

resolve_version() {
  git_repo rev-parse --quiet --verify "refs/tags/lens-v$POCKET_LENS_VERSION^{commit}"
}

build_release() {
  local sha="$1" release="$LENS_DIR/releases/$1"
  [[ -f "$release/$BUILT_MARKER" ]] && return
  if [[ -e "$release" ]]; then
    git_repo worktree remove --force "$release" 2>/dev/null || rm -rf "$release"
    git_repo worktree prune
  fi
  echo "Building pocket-lens $POCKET_LENS_VERSION ($sha)..."
  git_repo worktree add --quiet --detach "$release" "$sha"
  (
    cd "$release"
    HUSKY=0 pnpm install --frozen-lockfile
    NX_DAEMON=false NX_NO_CLOUD=true pnpm exec nx run lens-cli:build
    uv sync --frozen --project apps/lens-embedder
  )
  [[ -f "$release/apps/lens-cli/dist/pocket-lens.mjs" ]] || {
    echo "The build of $sha did not produce the CLI." >&2
    exit 1
  }
  touch "$release/$BUILT_MARKER"
}

current_sha() {
  local target
  target="$(readlink "$LENS_DIR/current" 2>/dev/null)" || return 1
  basename "$target"
}

switch_to() {
  ln -sfn "releases/$1" "$LENS_DIR/current.new"
  mv -fh "$LENS_DIR/current.new" "$LENS_DIR/current"
}

# The token the server's LENS_INGEST_TOKEN expects, readable by the owner only.
write_token() {
  mkdir -p "$(dirname "$TOKEN_FILE")"
  (umask 077 && printf '%s\n' "$POCKET_LENS_INGEST_TOKEN" > "$TOKEN_FILE")
}

# `pocket-lens` with the library and the server set, for the terminal.
write_wrapper() {
  mkdir -p "$LENS_DIR/bin" "$LIBRARY/inbox"
  cat > "$LENS_DIR/bin/pocket-lens" <<WRAPPER
#!/usr/bin/env bash
export PATH="$(brew --prefix)/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export LENS_LIBRARY_ROOT="$LIBRARY"
export LENS_API_URL="http://127.0.0.1:$API_PORT"
export LENS_INGEST_TOKEN_FILE="$TOKEN_FILE"
exec "$(command -v node)" "$LENS_DIR/current/apps/lens-cli/dist/pocket-lens.mjs" "\$@"
WRAPPER
  chmod 755 "$LENS_DIR/bin/pocket-lens"
  ln -sfn "$LENS_DIR/bin/pocket-lens" "$(brew --prefix)/bin/pocket-lens"
}

render_agent() {
  local label="$1" agent="$HOME/Library/LaunchAgents/$1.plist"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/pocket-cloud"
  sed -e "s|__LENS_DIR__|$LENS_DIR|g" \
      -e "s|__EMBEDDER_PORT__|$EMBEDDER_PORT|g" \
      -e "s|__BREW_PREFIX__|$(brew --prefix)|g" \
      -e "s|__HOME__|$HOME|g" \
      "$REPO_ROOT/launchd/$label.plist" > "$agent"
  plutil -lint "$agent" >/dev/null
}

load_agent() {
  local label="$1"
  if is_loaded "$label"; then
    launchctl bootout "$DOMAIN/$label"
    for _ in {1..20}; do is_loaded "$label" || break; sleep 0.5; done
  fi
  launchctl bootstrap "$DOMAIN" "$HOME/Library/LaunchAgents/$label.plist"
}

# Unloads and removes the agents of lens 0.4 and earlier.
retire_agents() {
  local label
  for label in "${RETIRED_LABELS[@]}"; do
    if is_loaded "$label"; then launchctl bootout "$DOMAIN/$label"; echo "Retired $label."; fi
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
  done
}

# Uploads that lens 0.4 left in its uploads folder go into the inbox, where the server files them.
# Only verified files (`<id>/<name>`) move; the folder goes once nothing is left in it.
move_old_uploads() {
  local file target name n
  [[ -d "$UPLOADS" ]] || return 0
  while IFS= read -r -d '' file; do
    name="$(basename "$file")"
    target="$LIBRARY/inbox/$name"
    n=2
    while [[ -e "$target" ]]; do
      target="$LIBRARY/inbox/${name%.*}-$n.${name##*.}"
      n=$((n + 1))
    done
    mv -n "$file" "$target" && echo "Moved the upload $name into the inbox."
  done < <(find "$UPLOADS" -mindepth 2 -maxdepth 2 -type f -not -path "$UPLOADS/.partial/*" -print0)
  find "$UPLOADS" -mindepth 1 -type d -empty -delete
  if rmdir "$UPLOADS" 2>/dev/null; then
    echo "Removed the empty $UPLOADS."
  else
    echo "$UPLOADS still holds files (unfinished uploads?); look and remove it by hand." >&2
  fi
}

prune_releases() {
  local current kept=0 release
  current="$(current_sha || true)"
  while read -r release; do
    [[ "$release" == "$current" ]] && continue
    if (( ++kept < KEEP_RELEASES )); then continue; fi
    git_repo worktree remove --force "$LENS_DIR/releases/$release" 2>/dev/null \
      || rm -rf "${LENS_DIR:?}/releases/$release"
  done < <(ls -1t "$LENS_DIR/releases")
  git_repo worktree prune
}

install() {
  local sha
  check_requirements
  if [[ ! -d "$LENS_DIR/repo/.git" ]] || ! sha="$(resolve_version)"; then fetch; fi
  sha="$(resolve_version)" || {
    echo "lens-v$POCKET_LENS_VERSION is not a tag of pocket-lens." >&2
    exit 1
  }
  build_release "$sha"
  switch_to "$sha"
  write_token
  write_wrapper
  move_old_uploads
  render_agent "$EMBEDDER_LABEL"
  if ! has_gui_domain; then
    echo "No desktop session ($DOMAIN); the worker loads at the next login."
    return
  fi
  retire_agents
  load_agent "$EMBEDDER_LABEL"
  prune_releases
  echo "Registered $EMBEDDER_LABEL (127.0.0.1:$EMBEDDER_PORT), pocket-lens $POCKET_LENS_VERSION ($sha)."
  echo "Library: $LIBRARY (set it as the Wireless Transmitter Utility destination: $LIBRARY/inbox)"
}

uninstall() {
  if is_loaded "$EMBEDDER_LABEL"; then
    launchctl bootout "$DOMAIN/$EMBEDDER_LABEL"
    echo "Unregistered $EMBEDDER_LABEL."
  fi
  rm -f "$HOME/Library/LaunchAgents/$EMBEDDER_LABEL.plist"
  retire_agents
  rm -f "$(brew --prefix)/bin/pocket-lens"
  echo "Releases, the library and $TOKEN_FILE are kept."
}

status() {
  local label code
  for label in "$EMBEDDER_LABEL" "${RETIRED_LABELS[@]}"; do
    if is_loaded "$label"; then echo "$label: loaded"; else echo "$label: not loaded"; fi
  done
  echo "release: $(current_sha || echo none)"
  code="$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$API_PORT/health/ready" || true)"
  echo "server on 127.0.0.1:$API_PORT: $([[ "$code" == 200 ]] && echo up || echo "not answering ($code)")"
}

# The same request as Import now, with the ingest token.
request_import() {
  curl -fsS -m 5 -X POST -H "Authorization: Bearer $POCKET_LENS_INGEST_TOKEN" \
    "http://127.0.0.1:$API_PORT/api/v1/ingest/imports" >/dev/null
  echo "Import requested; the gallery's runs page shows how it goes."
}

case "${1:-install}" in
  install) install ;;
  update) check_requirements; fetch; install ;;
  uninstall) uninstall ;;
  status) status ;;
  run) request_import ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac

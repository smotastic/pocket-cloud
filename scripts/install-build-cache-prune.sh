#!/usr/bin/env bash
# Run scripts/prune-build-cache.sh every 15 minutes via a launchd agent, so CI
# builds can't fill the Colima VM's data disk with BuildKit cache.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="dev.pocket-cloud.build-cache-prune"
TEMPLATE="$REPO_ROOT/launchd/$LABEL.plist"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
LOG="$HOME/Library/Logs/pocket-cloud/build-cache-prune.log"

usage() {
  cat <<'USAGE'
Usage: scripts/install-build-cache-prune.sh [install|uninstall|status|run-now]

  install    Register the launchd agent (every 15 minutes) (default)
  uninstall  Unregister the launchd agent
  status     Show the agent state and the end of the log
  run-now    Prune once, in this shell
USAGE
}

is_loaded() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

install() {
  local brew_prefix
  brew_prefix="$(brew --prefix)"
  # Fails here, not every 15 minutes in the log, when colima or docker is missing.
  "$REPO_ROOT/scripts/prune-build-cache.sh"

  mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"
  sed -e "s|__REPO_ROOT__|$REPO_ROOT|g" \
      -e "s|__HOME__|$HOME|g" \
      -e "s|__BREW_PREFIX__|$brew_prefix|g" \
      "$TEMPLATE" > "$AGENT"
  plutil -lint "$AGENT" >/dev/null

  # Over SSH without a desktop session the gui domain doesn't exist; the agent
  # then loads at the next desktop login, like dev.pocket-cloud.colima.
  if ! launchctl print "$DOMAIN" >/dev/null 2>&1; then
    echo "No desktop session ($DOMAIN); $LABEL will load at the next login."
    return
  fi
  if is_loaded; then
    launchctl bootout "$DOMAIN/$LABEL"
  fi
  launchctl bootstrap "$DOMAIN" "$AGENT"
  echo "Registered $LABEL (every 15 minutes)."
}

uninstall() {
  if is_loaded; then
    launchctl bootout "$DOMAIN/$LABEL"
    echo "Unregistered $LABEL."
  fi
  rm -f "$AGENT"
}

status() {
  if is_loaded; then
    launchctl print "$DOMAIN/$LABEL" | grep -E $'^\t(state|last exit code) ='
  elif [[ -f "$AGENT" ]]; then
    echo "$LABEL is installed and loads at the next desktop login."
  else
    echo "$LABEL is not installed."
  fi
  tail -n 5 "$LOG" 2>/dev/null || true
}

case "${1:-install}" in
  install) install ;;
  uninstall) uninstall ;;
  status) status ;;
  run-now) "$REPO_ROOT/scripts/prune-build-cache.sh" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac

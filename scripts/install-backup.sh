#!/usr/bin/env bash
# Schedule scripts/backup.sh daily via a launchd agent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="dev.pocket-cloud.backup"
TEMPLATE="$REPO_ROOT/launchd/$LABEL.plist"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

usage() {
  cat <<'USAGE'
Usage: scripts/install-backup.sh [install|uninstall|status|run-now]

  install    Register the launchd agent (daily 03:30) (default)
  uninstall  Unregister the launchd agent; snapshots are kept
  status     Show the agent state and the end of the backup log
  run-now    Start the scheduled job once, as launchd runs it
USAGE
}

is_loaded() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

install() {
  command -v restic >/dev/null || { echo "restic not found. Run ./bootstrap.sh brew in the setup repo." >&2; exit 1; }

  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/pocket-cloud"
  sed -e "s|__REPO_ROOT__|$REPO_ROOT|g" \
      -e "s|__BREW_PREFIX__|$(brew --prefix)|g" \
      -e "s|__HOME__|$HOME|g" \
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
  echo "Registered $LABEL (daily 03:30)."
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
    launchctl print "$DOMAIN/$LABEL" | grep -E '^\s*(state|last exit code) ='
  elif [[ -f "$AGENT" ]]; then
    echo "$LABEL is installed and loads at the next desktop login."
  else
    echo "$LABEL is not installed."
  fi
  tail -n 5 "$HOME/Library/Logs/pocket-cloud/backup.log" 2>/dev/null || true
}

case "${1:-install}" in
  install) install ;;
  uninstall) uninstall ;;
  status) status ;;
  run-now) launchctl kickstart -p "$DOMAIN/$LABEL" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac

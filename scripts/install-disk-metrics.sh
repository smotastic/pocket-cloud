#!/usr/bin/env bash
# Run scripts/disk-metrics.sh every minute via a launchd agent, so Prometheus
# knows how full the Mac's disk is.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="dev.pocket-cloud.disk-metrics"
TEMPLATE="$REPO_ROOT/launchd/$LABEL.plist"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
LOG="$HOME/Library/Logs/pocket-cloud/disk-metrics.log"

usage() {
  cat <<'USAGE'
Usage: scripts/install-disk-metrics.sh [install|uninstall|status|run-now]

  install    Register the launchd agent (every minute) (default)
  uninstall  Unregister the launchd agent
  status     Show the agent state and the end of the log
  run-now    Push the metrics once, in this shell
USAGE
}

is_loaded() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

install() {
  # Fails here, not every minute in the log, when Prometheus isn't reachable.
  "$REPO_ROOT/scripts/disk-metrics.sh"

  mkdir -p "$HOME/Library/LaunchAgents" "$(dirname "$LOG")"
  sed -e "s|__REPO_ROOT__|$REPO_ROOT|g" \
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
  echo "Registered $LABEL (every minute)."
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
  run-now) "$REPO_ROOT/scripts/disk-metrics.sh" && echo "Pushed." ;;
  -h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac

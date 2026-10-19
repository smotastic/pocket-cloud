#!/usr/bin/env bash
# Start the pocket-cloud Colima VM automatically at login via a launchd agent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="dev.pocket-cloud.colima"
TEMPLATE="$REPO_ROOT/launchd/$LABEL.plist"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

# VM settings, applied only when the profile is created for the first time.
# Change an existing profile with: colima stop -p pocket-cloud && colima start -p pocket-cloud --cpus N ...
PROFILE="pocket-cloud"
CPUS=4
MEMORY=8
DISK=100

usage() {
  cat <<'USAGE'
Usage: scripts/install-autostart.sh [install|uninstall|status]

  install    Create the Colima profile if needed and register the launchd agent (default)
  uninstall  Unregister the launchd agent; the VM and its data are kept
  status     Show the agent and VM state
USAGE
}

is_loaded() {
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1
}

profile_exists() {
  [[ -f "$HOME/.colima/$PROFILE/colima.yaml" ]]
}

install() {
  local colima brew_prefix

  colima="$(command -v colima)" || { echo "colima not found. Run ./bootstrap.sh brew in the setup repo." >&2; exit 1; }
  brew_prefix="$(brew --prefix)"

  # The agent only runs `colima start <profile>`, which would create the VM with
  # Colima's defaults. Create it once here with our settings, then stop it so
  # launchd owns the running instance.
  if ! profile_exists; then
    echo "Creating Colima profile $PROFILE ($CPUS CPUs, ${MEMORY} GiB RAM, ${DISK} GiB disk)..."
    "$colima" start "$PROFILE" --vm-type vz --mount-type virtiofs \
      --cpus "$CPUS" --memory "$MEMORY" --disk "$DISK" --activate=false
    "$colima" stop "$PROFILE"
  elif launchctl print "$DOMAIN" >/dev/null 2>&1 && ! is_loaded \
      && "$colima" status "$PROFILE" >/dev/null 2>&1; then
    echo "Stopping manually started $PROFILE VM so launchd can take it over..."
    "$colima" stop "$PROFILE"
  fi

  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/pocket-cloud"
  sed -e "s|__COLIMA__|$colima|g" \
      -e "s|__PROFILE__|$PROFILE|g" \
      -e "s|__BREW_PREFIX__|$brew_prefix|g" \
      -e "s|__HOME__|$HOME|g" \
      "$TEMPLATE" > "$AGENT"
  plutil -lint "$AGENT" >/dev/null

  # The gui domain only exists while someone is logged in at the desktop. Over
  # SSH without one, launchd loads the agent at the next desktop login (which
  # FileVault's unlock after a reboot also is); start the VM directly until then.
  # If the agent later finds the VM running, `colima start` exits and launchd
  # retries every ThrottleInterval, taking over as soon as the VM goes down.
  if ! launchctl print "$DOMAIN" >/dev/null 2>&1; then
    echo "No desktop session ($DOMAIN); $LABEL will load at the next login."
    echo "Starting the VM directly for now..."
    "$colima" start "$PROFILE" --activate=false
    return
  fi

  if is_loaded; then
    launchctl bootout "$DOMAIN/$LABEL"
  fi
  launchctl bootstrap "$DOMAIN" "$AGENT"
  echo "Registered $LABEL. Waiting for the VM to come up..."

  for _ in {1..60}; do
    if "$colima" status "$PROFILE" >/dev/null 2>&1; then
      echo "Colima profile $PROFILE is running."
      return
    fi
    sleep 2
  done
  echo "VM did not report running within 2 minutes; check ~/Library/Logs/pocket-cloud/colima.log" >&2
  exit 1
}

uninstall() {
  if is_loaded; then
    # Unloading sends SIGTERM to `colima start --foreground`, which stops the VM.
    launchctl bootout "$DOMAIN/$LABEL"
    echo "Unregistered $LABEL."
  fi
  rm -f "$AGENT"
}

status() {
  if is_loaded; then
    launchctl print "$DOMAIN/$LABEL" | grep -E '^\s*(state|pid|last exit code) ='
  elif [[ -f "$AGENT" ]]; then
    echo "$LABEL is installed and loads at the next desktop login."
  else
    echo "$LABEL is not installed."
  fi
  colima status "$PROFILE" 2>&1 || true
}

case "${1:-install}" in
  install) install ;;
  uninstall) uninstall ;;
  status) status ;;
  -h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac

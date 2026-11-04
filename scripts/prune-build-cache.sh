#!/usr/bin/env bash
# Prune the Colima VM's BuildKit cache by age. Run every 15 minutes by the launchd
# agent from scripts/install-build-cache-prune.sh. BuildKit's own GC policy
# (docker.builder.gc in the Colima profile) doesn't cap the cache with the containerd
# image store: it counts most records as shared and skips them, see
# https://github.com/moby/buildkit/issues/7352. `--max-used-space` and
# `--keep-storage` skip them the same way; only an age filter frees them.
set -euo pipefail

PROFILE="pocket-cloud"
# Above this much of the data disk used, keep only the last 2 h of cache, else 12 h.
BUSY_PERCENT="${PRUNE_BUSY_PERCENT:-70}"

# A set DOCKER_HOST would override the context and hit the dev VM.
unset DOCKER_HOST
export DOCKER_CONTEXT="colima-$PROFILE"

if ! colima status "$PROFILE" >/dev/null 2>&1; then
  echo "$(date '+%F %T') VM $PROFILE is not running, skipping."
  exit 0
fi

used_percent() {
  colima ssh -p "$PROFILE" -- df -P /var/lib/docker | awk 'NR == 2 { sub("%", "", $5); print $5 }'
}

before="$(used_percent)"
if (( before >= BUSY_PERCENT )); then
  until="2h"
else
  until="12h"
fi

reclaimed="$(docker builder prune -af --filter "until=$until" | awk '/^Total:/ { print $2 }')"
echo "$(date '+%F %T') disk ${before}% -> $(used_percent)%, pruned cache older than $until (${reclaimed:-0B})"

#!/usr/bin/env bash
# Push the size and free space of the Mac's disk that holds DATA_ROOT to Prometheus
# over OTLP, for the MacDisk* alerts. Run every minute by the launchd agent from
# scripts/install-disk-metrics.sh. node-exporter in the Colima VM can't do this:
# it sees DATA_ROOT only as the virtiofs mount, which reports a meaningless size.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

set -a
# shellcheck source=/dev/null
source "$REPO_ROOT/.env"
set +a

ENDPOINT="http://127.0.0.1:${PROMETHEUS_PORT:-9090}/api/v1/otlp/v1/metrics"

# POSIX output in 1024-byte blocks: filesystem, size, used, available, capacity, mount point.
# On APFS the size is the container's, shared by its volumes, so 1 - avail/size is
# how full the disk is, not just this volume.
read -r _ size_kb _ avail_kb _ mountpoint < <(df -kP "$DATA_ROOT" | tail -n 1)
# Milliseconds, Prometheus' resolution: with whole seconds, two runs in the same second
# (install, then the agent's first run) collide and the second is rejected with a 400.
now_ns="$(perl -MTime::HiRes=time -e 'printf "%d000000", time * 1000')"

gauge() {
  cat <<JSON
{"name": "$1", "gauge": {"dataPoints": [{"asInt": "$2", "timeUnixNano": "$now_ns",
  "attributes": [{"key": "mountpoint", "value": {"stringValue": "$mountpoint"}}]}]}}
JSON
}

# No unit on the metrics, so Prometheus keeps the names as they are.
# service.name becomes the job label.
curl -fsS -m 10 -o /dev/null -X POST "$ENDPOINT" -H 'Content-Type: application/json' -d @- <<JSON
{"resourceMetrics": [{
  "resource": {"attributes": [{"key": "service.name", "value": {"stringValue": "mac-disk"}}]},
  "scopeMetrics": [{"scope": {"name": "pocket-cloud/disk-metrics"}, "metrics": [
    $(gauge mac_filesystem_size_bytes $((size_kb * 1024))),
    $(gauge mac_filesystem_avail_bytes $((avail_kb * 1024)))
  ]}]
}]}
JSON

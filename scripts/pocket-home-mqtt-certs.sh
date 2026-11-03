#!/usr/bin/env bash
# The TLS certificates of pocket-home's MQTT broker: a dedicated CA and a broker
# certificate signed by it. The CA key stays in DATA_ROOT on the Mac and is never mounted
# into a container; the broker gets its certificate, its key and the CA certificate.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

set -a
# shellcheck source=/dev/null
source .env
set +a

CA_DIR="$DATA_ROOT/pocket-home/mqtt-ca"
CERT_DIR="$DATA_ROOT/pocket-home/mosquitto/config/certs"
CA_DAYS=3650
BROKER_DAYS=825

usage() {
  cat <<'USAGE'
Usage: scripts/pocket-home-mqtt-certs.sh [create|renew|status] [name...]

  create   Create the CA and the broker certificate, each only if missing (default)
  renew    Issue a new broker certificate with the same CA, e.g. before it expires
           or when the gateway reaches the broker under a new name
  status   Show the names and expiry dates

The broker certificate names pocket-home-mosquitto (the ingestor), localhost, this Mac's
.local name and LAN address (the gateway), and every extra name given. Restart the broker
afterwards: docker compose up -d --force-recreate pocket-home-mosquitto
USAGE
}

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# The names the clients use to reach the broker, as subjectAltName entries.
subject_alt_names() {
  local names=(pocket-home-mosquitto localhost "$(scutil --get LocalHostName).local" "$@")
  local ips=(127.0.0.1)
  local interface lan_ip
  interface="$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')"
  if [[ -n "$interface" ]] && lan_ip="$(ipconfig getifaddr "$interface")"; then
    ips+=("$lan_ip")
  fi
  local entries=() name
  for name in "${names[@]}"; do
    if [[ "$name" =~ ^[0-9.]+$ ]]; then ips+=("$name"); else entries+=("DNS:$name"); fi
  done
  for name in "${ips[@]}"; do entries+=("IP:$name"); done
  local IFS=,
  echo "${entries[*]}"
}

create_ca() {
  if [[ -f "$CA_DIR/ca.key" ]]; then
    log "CA exists in $CA_DIR"
    return
  fi
  mkdir -p "$CA_DIR"
  chmod 0700 "$CA_DIR"
  log "Creating the CA in $CA_DIR"
  (umask 077 && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$CA_DIR/ca.key")
  openssl req -x509 -new -key "$CA_DIR/ca.key" -sha256 -days "$CA_DAYS" \
    -subj "/CN=pocket-home MQTT CA" -out "$CA_DIR/ca.crt" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
}

issue_broker() {
  local san ext
  san="$(subject_alt_names "$@")"
  mkdir -p "$CERT_DIR"
  ext="$(mktemp)"
  trap 'rm -f "$ext" "$CERT_DIR/broker.csr"' RETURN
  printf '%s\n' "basicConstraints=critical,CA:FALSE" "keyUsage=critical,digitalSignature" \
    "extendedKeyUsage=serverAuth" "subjectAltName=$san" >"$ext"
  log "Issuing the broker certificate for $san"
  (umask 077 && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$CERT_DIR/broker.key")
  openssl req -new -key "$CERT_DIR/broker.key" -subj "/CN=pocket-home-mosquitto" \
    -out "$CERT_DIR/broker.csr"
  openssl x509 -req -in "$CERT_DIR/broker.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
    -CAcreateserial -CAserial "$CA_DIR/ca.srl" -sha256 -days "$BROKER_DAYS" -extfile "$ext" \
    -out "$CERT_DIR/broker.crt"
  cp "$CA_DIR/ca.crt" "$CERT_DIR/ca.crt"
  chmod 0644 "$CERT_DIR/ca.crt" "$CERT_DIR/broker.crt"
}

status() {
  local cert
  for cert in "$CA_DIR/ca.crt" "$CERT_DIR/broker.crt"; do
    if [[ ! -f "$cert" ]]; then
      echo "$cert: missing"
      continue
    fi
    echo "$cert:"
    openssl x509 -in "$cert" -noout -subject -enddate -ext subjectAltName 2>/dev/null | sed 's/^/  /'
  done
}

command="${1:-create}"
[[ $# -gt 0 ]] && shift
case "$command" in
  create)
    create_ca
    if [[ -f "$CERT_DIR/broker.crt" ]]; then
      log "Broker certificate exists in $CERT_DIR; use renew for a new one"
    else
      issue_broker "$@"
    fi
    ;;
  renew)
    [[ -f "$CA_DIR/ca.key" ]] || { echo "No CA in $CA_DIR; run create first." >&2; exit 1; }
    issue_broker "$@"
    ;;
  status) status ;;
  -h|--help) usage ;;
  *) usage >&2; exit 1 ;;
esac

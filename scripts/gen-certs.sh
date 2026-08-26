#!/bin/sh
# Генерация TLS для Grafana вне Docker (Linux-хост).
# В docker compose cert-init делает то же самое автоматически.
set -e
set -u

CERT_DIR="${1:-./certs}"
CN="${GRAFANA_CERT_CN:-ids-grafana}"
DAYS="${GRAFANA_TLS_DAYS:-825}"
SAN="${GRAFANA_CERT_SAN:-DNS:localhost,IP:127.0.0.1}"

mkdir -p "$CERT_DIR"

if [ -f "$CERT_DIR/grafana.crt" ] && [ -f "$CERT_DIR/grafana.key" ]; then
  echo "TLS certs already present in $CERT_DIR"
  exit 0
fi

command -v openssl >/dev/null 2>&1 || { echo "install openssl" >&2; exit 1; }

openssl req -x509 -nodes -days "$DAYS" -newkey rsa:2048 \
  -keyout "$CERT_DIR/grafana.key" \
  -out "$CERT_DIR/grafana.crt" \
  -subj "/CN=${CN}" \
  -addext "subjectAltName=${SAN}"

chmod 644 "$CERT_DIR/grafana.crt" "$CERT_DIR/grafana.key"
echo "Generated $CERT_DIR/grafana.crt (CN=${CN}, SAN=${SAN})"
# Linux hardening (опционально): chown 472:0 "$CERT_DIR/grafana.key" && chmod 640 "$CERT_DIR/grafana.key"

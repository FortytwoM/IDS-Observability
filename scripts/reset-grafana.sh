#!/usr/bin/env bash
# Force Grafana to re-provision dashboards/alerts from files.
# Use when the UI still shows an old provisioned board (UID stuck in grafana.db).
# Docs: https://grafana.com/docs/grafana/latest/administration/provisioning/
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Stopping Grafana..."
docker compose stop grafana
docker compose rm -f grafana

echo "Removing grafana-data volume (dashboards DB)..."
docker volume rm ids-observability_grafana-data 2>/dev/null || true

echo "Starting Grafana..."
docker compose up -d grafana

echo "Done. Open IDS → IDS: Suricata и Zeek (Ctrl+F5)."

#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

source runtime/scripts/engine.sh
require_quadlet_privileges || exit 1

echo "=== Stopping autoscaler ==="
runtime/scripts/autoscaler-control.sh stop || true

echo
echo "=== Stopping sietch override publisher ==="
runtime/scripts/publish-sietch-overrides.sh stop || true

echo
echo "=== Stopping Deep Desert warm-up publisher ==="
runtime/scripts/publish-deepdesert-overrides.sh stop || true

echo
echo "=== Stopping game servers first ==="
dune_systemctl stop dune-server-overmap.service dune-server-survival-1.service 2>/dev/null || true
engine rm -f dune-server-overmap dune-server-survival-1 2>/dev/null || true

echo
echo "=== Stopping gateway/director/router ==="
dune_systemctl stop dune-server-gateway.service dune-director.service dune-text-router.service 2>/dev/null || true
engine rm -f dune-server-gateway dune-director dune-text-router 2>/dev/null || true

echo
echo "=== Stopping RabbitMQ ==="
dune_systemctl stop dune-rmq-game.service dune-rmq-admin.service 2>/dev/null || true
engine rm -f dune-rmq-game dune-rmq-admin 2>/dev/null || true

echo
echo "=== Stopping Postgres ==="
dune_systemctl stop dune-postgres.service 2>/dev/null || true
engine rm -f dune-postgres 2>/dev/null || true

echo
echo "=== Remaining dune containers ==="
engine ps --filter "name=dune-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

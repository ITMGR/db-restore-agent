#!/usr/bin/env bash
set -euo pipefail

METRICS_ENABLED="${METRICS_ENABLED:-true}"
METRICS_PID=""
DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"

shutdown() {
  if [ -n "$METRICS_PID" ] && kill -0 "$METRICS_PID" 2>/dev/null; then
    kill "$METRICS_PID" 2>/dev/null || true
    wait "$METRICS_PID" 2>/dev/null || true
  fi
}

trap shutdown EXIT INT TERM

# Wait for MariaDB connectivity before starting anything
echo "Waiting for MariaDB at $DB_HOST:$DB_PORT ..."
for i in $(seq 1 60); do
  if mariadb-admin ping \
      --host="$DB_HOST" \
      --port="$DB_PORT" \
      --user="${MARIADB_USER:-crz}" \
      --password="${MARIADB_PASSWORD:-}" \
      --silent >/dev/null 2>&1; then
    echo "MariaDB is ready at $DB_HOST:$DB_PORT (attempt $i)"
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "ERROR: MariaDB not ready at $DB_HOST:$DB_PORT after 60s" >&2
    exit 1
  fi
  sleep 1
done

if [ "$METRICS_ENABLED" = "true" ]; then
  python3 /opt/crz-opt-scripts/restore-metrics.py &
  METRICS_PID="$!"
fi

bash /opt/crz-opt-scripts/watch-dumps.sh

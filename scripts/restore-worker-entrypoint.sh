#!/usr/bin/env bash
set -euo pipefail

METRICS_ENABLED="${METRICS_ENABLED:-true}"
METRICS_PID=""

shutdown() {
  if [ -n "$METRICS_PID" ] && kill -0 "$METRICS_PID" 2>/dev/null; then
    kill "$METRICS_PID" 2>/dev/null || true
    wait "$METRICS_PID" 2>/dev/null || true
  fi
}

trap shutdown EXIT INT TERM

if [ "$METRICS_ENABLED" = "true" ]; then
  python3 /opt/crz-opt-scripts/restore-metrics.py &
  METRICS_PID="$!"
fi

bash /opt/crz-opt-scripts/watch-dumps.sh

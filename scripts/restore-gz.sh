#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"

require_dump_arg "${1:-}"

DUMP_FILE="$1"
MODE="${RESTORE_MODE:-baseline}"
CONTAINER_DUMP="$(dump_container_path "$DUMP_FILE")"
RUNS_DIR="$PROJECT_DIR/data/restore-runs"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$MODE"
RUN_LOG="$RUNS_DIR/$RUN_ID.log"

mkdir -p "$RUNS_DIR"

"${COMPOSE[@]}" up -d db >/dev/null
wait_for_db

echo "restore_run=$RUN_ID" | tee "$RUN_LOG"
echo "dump=$DUMP_FILE" | tee -a "$RUN_LOG"
echo "mode=$MODE" | tee -a "$RUN_LOG"
echo "started_at_utc=$(date -u +%FT%TZ)" | tee -a "$RUN_LOG"

START_EPOCH="$(date +%s)"

case "$MODE" in
  baseline)
    "${COMPOSE[@]}" exec -T db /opt/crz-opt-scripts/container-restore.sh baseline "$CONTAINER_DUMP" 2>&1 | tee -a "$RUN_LOG"
    ;;
  fast|aggressive|pruned-data)
    "${COMPOSE[@]}" exec -T db /opt/crz-opt-scripts/container-restore.sh "$MODE" "$CONTAINER_DUMP" 2>&1 | tee -a "$RUN_LOG"
    ;;
  *)
    echo "Unknown RESTORE_MODE=$MODE. Use baseline, fast, aggressive or pruned-data." >&2
    exit 2
    ;;
esac

END_EPOCH="$(date +%s)"
DURATION="$((END_EPOCH - START_EPOCH))"

echo "finished_at_utc=$(date -u +%FT%TZ)" | tee -a "$RUN_LOG"
echo "duration_seconds=$DURATION" | tee -a "$RUN_LOG"
echo "$RUN_ID,$MODE,$DUMP_FILE,$DURATION" >> "$RUNS_DIR/results.csv"

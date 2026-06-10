#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/sql-lib.sh"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

require_dump_arg "${1:-}"

DUMP_FILE="$1"
MODE="${RESTORE_MODE:-baseline}"
RUNS_DIR="$PROJECT_DIR/data/restore-runs"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$MODE"
RUN_LOG="$RUNS_DIR/$RUN_ID.log"

if [ ! -f "$DUMP_FILE" ]; then
  echo "Dump not found: $DUMP_FILE" >&2
  exit 2
fi

mkdir -p "$RUNS_DIR"
wait_for_sql_db

echo "restore_run=$RUN_ID" | tee "$RUN_LOG"
echo "dump=$DUMP_FILE" | tee -a "$RUN_LOG"
echo "mode=$MODE" | tee -a "$RUN_LOG"
echo "started_at_utc=$(date -u +%FT%TZ)" | tee -a "$RUN_LOG"

START_EPOCH="$(date +%s)"

case "$MODE" in
  baseline)
    gzip -dc "$DUMP_FILE" | db_client_database 2>&1 | tee -a "$RUN_LOG"
    ;;
  fast|aggressive)
    {
      printf "%s\n" "SET SESSION sql_log_bin=0;"
      printf "%s\n" "SET SESSION unique_checks=0;"
      printf "%s\n" "SET SESSION foreign_key_checks=0;"
      printf "%s\n" "SET SESSION autocommit=0;"
      gzip -dc "$DUMP_FILE"
      printf "%s\n" "COMMIT;"
    } | db_client_database 2>&1 | tee -a "$RUN_LOG"
    ;;
  pruned-data)
    {
      printf "%s\n" "SET SESSION sql_log_bin=0;"
      printf "%s\n" "SET SESSION unique_checks=0;"
      printf "%s\n" "SET SESSION foreign_key_checks=0;"
      printf "%s\n" "SET SESSION autocommit=0;"
      gzip -dc "$DUMP_FILE" | awk -v prune_re="$PRUNE_DATA_TABLE_REGEX" -f "$SCRIPTS_DIR/filter-pruned-data.awk"
      printf "%s\n" "COMMIT;"
    } | db_client_database 2>&1 | tee -a "$RUN_LOG"
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

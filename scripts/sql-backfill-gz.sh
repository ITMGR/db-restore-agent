#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/sql-lib.sh"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

require_dump_arg "${1:-}"

DUMP_FILE="$1"
RUNS_DIR="$PROJECT_DIR/data/restore-runs"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-backfill"
RUN_LOG="$RUNS_DIR/$RUN_ID.log"

if [ ! -f "$DUMP_FILE" ]; then
  echo "Dump not found: $DUMP_FILE" >&2
  exit 2
fi

mkdir -p "$RUNS_DIR"
wait_for_sql_db

echo "backfill_run=$RUN_ID" | tee "$RUN_LOG"
echo "dump=$DUMP_FILE" | tee -a "$RUN_LOG"
echo "started_at_utc=$(date -u +%FT%TZ)" | tee -a "$RUN_LOG"
echo "[backfill] tabuľky na backfill: $PRUNE_DATA_TABLE_REGEX" | tee -a "$RUN_LOG"

START_EPOCH="$(date +%s)"
BACKFILL_RE_SQL="$(sql_quote_string "$PRUNE_DATA_TABLE_REGEX")"

BACKFILL_TABLES=$(db_client_database \
  --skip-column-names \
  --batch \
  -e "SELECT TABLE_NAME FROM information_schema.tables WHERE table_schema=DATABASE() AND TABLE_NAME RLIKE $BACKFILL_RE_SQL AND COALESCE(TABLE_ROWS, 0) = 0 ORDER BY TABLE_NAME;" \
  2>/dev/null || true)

if [ -n "$BACKFILL_TABLES" ]; then
  {
    echo "[backfill] prázdne tabuľky na dohratie:"
    echo "$BACKFILL_TABLES" | while read -r table; do echo "  - $table"; done
  } | tee -a "$RUN_LOG"
else
  echo "[backfill] žiadne prázdne tabuľky nepasujú na regex, nothing to backfill" | tee -a "$RUN_LOG"
  exit 0
fi

BACKFILL_TABLE_FILTER=$(printf '%s\n' "$BACKFILL_TABLES" | awk '
  BEGIN { printf "^(" }
  {
    gsub(/[][(){}.^$*+?|\\]/, "\\\\&")
    if (NR > 1) {
      printf "|"
    }
    printf "%s", $0
  }
  END { print ")$" }
')

echo "[backfill] efektívny filter: $BACKFILL_TABLE_FILTER" | tee -a "$RUN_LOG"
echo "[backfill] spúšťam restore dát cez filter-backfill.awk..." | tee -a "$RUN_LOG"

{
  printf "%s\n" "SET SESSION unique_checks=0;"
  printf "%s\n" "SET SESSION foreign_key_checks=0;"
  printf "%s\n" "SET NAMES utf8mb4;"
  printf "%s\n" "USE \`$MARIADB_DATABASE\`;"
  gzip -dc "$DUMP_FILE" | awk -v backfill_re="$BACKFILL_TABLE_FILTER" -f "$SCRIPTS_DIR/filter-backfill.awk"
  printf "%s\n" "COMMIT;"
} | db_client_database 2>&1 | tee -a "$RUN_LOG"

END_EPOCH="$(date +%s)"
DURATION="$((END_EPOCH - START_EPOCH))"

echo "[backfill] dokončené" | tee -a "$RUN_LOG"
echo "finished_at_utc=$(date -u +%FT%TZ)" | tee -a "$RUN_LOG"
echo "duration_seconds=$DURATION" | tee -a "$RUN_LOG"
echo "$RUN_ID,backfill,$DUMP_FILE,$DURATION" >> "$RUNS_DIR/backfill-results.csv"

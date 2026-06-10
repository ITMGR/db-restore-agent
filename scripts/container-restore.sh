#!/usr/bin/env bash
set -e

MODE="${1:-}"
DUMP_FILE="${2:-}"

if [ -z "$MODE" ] || [ -z "$DUMP_FILE" ]; then
  echo "Usage: container-restore.sh baseline|fast|aggressive|pruned-data /dumps/<dump.sql.gz>" >&2
  exit 2
fi

if [ ! -f "$DUMP_FILE" ]; then
  echo "Dump not found in container: $DUMP_FILE" >&2
  exit 2
fi

ts() { date -u +"%a %Y-%m-%d %H:%M UTC"; }
log() { echo "[$(ts)] $1" >&2; }

# Get compressed size for pv progress bar
COMPRESSED_SIZE=$(gzip -l "$DUMP_FILE" 2>/dev/null | tail -1 | awk '{print $2}')
if [ -z "$COMPRESSED_SIZE" ] || [ "$COMPRESSED_SIZE" = "0" ]; then
  log "WARNING: could not determine compressed size, progress bar disabled"
  USE_PV=false
else
  log "compressed size: $COMPRESSED_SIZE bytes"
  USE_PV=true
fi

log "restore started — mode=$MODE file=$DUMP_FILE"

export MYSQL_PWD="$MARIADB_PASSWORD"
DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
PRUNE_DATA_TABLE_REGEX="${PRUNE_DATA_TABLE_REGEX:-^(log_[0-9]+|counter_[0-9]+|robot_01|robot_02|elastic1)$}"

client() {
  mariadb \
    --user="$MARIADB_USER" \
    --password="$MARIADB_PASSWORD" \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --database="$MARIADB_DATABASE" \
    --binary-mode \
    --show-warnings \
    --max_allowed_packet="${RESTORE_MAX_ALLOWED_PACKET:-1G}"
}

log "connected to $DB_HOST:$DB_PORT"

# Progress pipe: pv shows throughput and progress bar
# pv -p (progress) -t (time) -e (eta) -b (rate) -r (rate bytes)
progress_pv() {
  if [ "$USE_PV" = "true" ]; then
    pv -petrb -s "$COMPRESSED_SIZE"
  else
    cat
  fi
}

case "$MODE" in
  baseline)
    log "baseline restore — streaming gzip to mariadb with pv"
    gzip -dc "$DUMP_FILE" | progress_pv | client
    ;;

  fast|aggressive)
    log "$MODE restore — decompression + progress started"
    {
      printf "%s\n" "SET SESSION sql_log_bin=0;"
      printf "%s\n" "SET SESSION unique_checks=0;"
      printf "%s\n" "SET SESSION foreign_key_checks=0;"
      printf "%s\n" "SET SESSION autocommit=0;"
      gzip -dc "$DUMP_FILE" | progress_pv
      printf "%s\n" "COMMIT;"
    } | client
    log "data import done"
    ;;

  pruned-data)
    log "pruned-data restore — decompression + table filter + progress started"
    {
      printf "%s\n" "SET SESSION sql_log_bin=0;"
      printf "%s\n" "SET SESSION unique_checks=0;"
      printf "%s\n" "SET SESSION foreign_key_checks=0;"
      printf "%s\n" "SET SESSION autocommit=0;"
      gzip -dc "$DUMP_FILE" | progress_pv | awk -v prune_re="$PRUNE_DATA_TABLE_REGEX" -f /opt/crz-opt-scripts/filter-pruned-data.awk
      printf "%s\n" "COMMIT;"
    } | client
    log "pruned-data import done"
    ;;

  *)
    echo "Unknown restore mode: $MODE" >&2
    exit 2
    ;;
esac

log "restore complete"

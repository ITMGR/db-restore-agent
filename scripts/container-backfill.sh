#!/usr/bin/env bash
#
# container-backfill.sh — doleje prevádzkové dáta do už obnovenej databázy.
# Použitie po container-restore.sh pruned-data.
#
# Beží v restore-worker kontajnery:
#   docker compose exec restore-worker sh /opt/crz-opt-scripts/container-backfill.sh /dumps/mariadb_crz_crz-sql_20260510-231000.sql.gz
#
set -e

DUMP_FILE="${1:-}"

if [ -z "$DUMP_FILE" ]; then
  echo "Usage: container-backfill.sh /dumps/<dump.sql.gz>" >&2
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

log "backfill started — file=$DUMP_FILE"

# Počkať kým je DB pripravená
WAIT_FILE="/opt/crz-opt-scripts/container-wait-ready.sh"
if [ -x "$WAIT_FILE" ]; then
  log "čakám na MariaDB ready..."
  "$WAIT_FILE"
  log "MariaDB je ready"
else
  log "wait-ready script nenájdený, pokračujem..."
fi

export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"

# Tabuľky ktoré boli prerezané v pruned-data móde. V1 dohráva iba tabuľky,
# ktoré sú stále prázdne; tým sa vyhne duplicite pri opakovanom spustení.
BACKFILL_TABLE_REGEX="${PRUNE_DATA_TABLE_REGEX:-^(log_[0-9]+|counter_[0-9]+|robot_01|robot_02|elastic1)$}"

log "tabuľky na backfill: $BACKFILL_TABLE_REGEX"

BACKFILL_TABLES=$(mariadb \
  --user=root \
  --password="$MARIADB_ROOT_PASSWORD" \
  --host="$DB_HOST" \
  --port="$DB_PORT" \
  --database="$MARIADB_DATABASE" \
  --skip-column-names \
  --batch \
  -e "SELECT TABLE_NAME FROM information_schema.tables WHERE table_schema='$MARIADB_DATABASE' AND TABLE_NAME RLIKE '$BACKFILL_TABLE_REGEX' AND COALESCE(TABLE_ROWS, 0) = 0 ORDER BY TABLE_NAME;" \
  2>/dev/null || true)

if [ -n "$BACKFILL_TABLES" ]; then
  log "prázdne tabuľky na dohratie:"
  echo "$BACKFILL_TABLES" | while read -r t; do log "  - $t"; done
else
  log "žiadne prázdne tabuľky nepasujú na regex, nothing to backfill"
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

log "efektívny filter: $BACKFILL_TABLE_FILTER"
log "spúšťam restore dát cez filter-backfill.awk..."

client() {
  mariadb \
    --user=root \
    --password="$MARIADB_ROOT_PASSWORD" \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --database="$MARIADB_DATABASE" \
    --binary-mode \
    --show-warnings \
    --max_allowed_packet="${RESTORE_MAX_ALLOWED_PACKET:-1G}"
}

# Progress pipe: pv shows throughput and progress bar
progress_pv() {
  if [ "$USE_PV" = "true" ]; then
    pv -petrb -s "$COMPRESSED_SIZE"
  else
    cat
  fi
}

log "backfill data import started"
{
  printf "%s\n" "SET SESSION sql_log_bin=0;"
  printf "%s\n" "SET SESSION unique_checks=0;"
  printf "%s\n" "SET SESSION foreign_key_checks=0;"
  printf "%s\n" "SET SESSION autocommit=0;"
  gzip -dc "$DUMP_FILE" | progress_pv | awk -v backfill_re="$BACKFILL_TABLE_FILTER" -f /opt/crz-opt-scripts/filter-backfill.awk
  printf "%s\n" "COMMIT;"
} | client

log "backfill complete"

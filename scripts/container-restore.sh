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

export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"
PRUNE_DATA_TABLE_REGEX="${PRUNE_DATA_TABLE_REGEX:-^(log_[0-9]+|counter_[0-9]+|robot_01|robot_02|elastic1)$}"

client() {
  mariadb \
    --user=root \
    --password="$MARIADB_ROOT_PASSWORD" \
    --database="$MARIADB_DATABASE" \
    --binary-mode \
    --show-warnings \
    --max_allowed_packet="${RESTORE_MAX_ALLOWED_PACKET:-1G}"
}

case "$MODE" in
  baseline)
    gzip -dc "$DUMP_FILE" | client
    ;;
  fast|aggressive)
    {
      printf "%s\n" "SET SESSION sql_log_bin=0;"
      printf "%s\n" "SET SESSION unique_checks=0;"
      printf "%s\n" "SET SESSION foreign_key_checks=0;"
      printf "%s\n" "SET SESSION autocommit=0;"
      gzip -dc "$DUMP_FILE"
      printf "%s\n" "COMMIT;"
    } | client
    ;;
  pruned-data)
    {
      printf "%s\n" "SET SESSION sql_log_bin=0;"
      printf "%s\n" "SET SESSION unique_checks=0;"
      printf "%s\n" "SET SESSION foreign_key_checks=0;"
      printf "%s\n" "SET SESSION autocommit=0;"
      gzip -dc "$DUMP_FILE" | awk -v prune_re="$PRUNE_DATA_TABLE_REGEX" -f /opt/crz-opt-scripts/filter-pruned-data.awk
      printf "%s\n" "COMMIT;"
    } | client
    ;;
  *)
    echo "Unknown restore mode: $MODE" >&2
    exit 2
    ;;
esac

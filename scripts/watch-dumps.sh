#!/usr/bin/env bash
set -euo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$PROJECT_DIR"

DUMP_WATCH_DIR="${DUMP_WATCH_DIR:-$PROJECT_DIR/data/dumps}"
RESTORE_STATE_DIR="${RESTORE_STATE_DIR:-$PROJECT_DIR/data/restore-state}"
RESTORE_POLL_INTERVAL="${RESTORE_POLL_INTERVAL:-60}"
RESTORE_STABLE_SECONDS="${RESTORE_STABLE_SECONDS:-120}"
RESTORE_ON_START="${RESTORE_ON_START:-true}"
RESTORE_WORKFLOW_MODE="${RESTORE_WORKFLOW_MODE:-pruned-data}"
RESTORE_AUTO_BACKFILL="${RESTORE_AUTO_BACKFILL:-true}"
RESTORE_GZIP_TEST="${RESTORE_GZIP_TEST:-false}"
DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
MARIADB_USER="${MARIADB_USER:-crz}"
MARIADB_PASSWORD="${MARIADB_PASSWORD:-}"
MARIADB_DATABASE="${MARIADB_DATABASE:-crz}"
PRUNE_DATA_TABLE_REGEX="${PRUNE_DATA_TABLE_REGEX:-^(log_[0-9]+|counter_[0-9]+|robot_01|robot_02|elastic1)$}"

mkdir -p "$RESTORE_STATE_DIR"

log() {
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"
}

dump_id() {
  local file="$1"
  stat -c '%n|%s|%Y' "$file"
}

last_success_id() {
  if [ -f "$RESTORE_STATE_DIR/last-success.id" ]; then
    cat "$RESTORE_STATE_DIR/last-success.id"
  fi
}

write_state_file() {
  local file="$1"
  local phase="$2"
  local status="$3"
  local state_file="$4"
  {
    echo "dump_file=$file"
    echo "phase=$phase"
    echo "status=$status"
    echo "updated_at=$(date -u +%FT%TZ)"
  } > "$state_file"
}

workflow() {
  local dump_file="$1"
  local dump_id
  dump_id="$(dump_id "$dump_file")"

  local previous_id
  previous_id="$(last_success_id)"

  if [ "$dump_id" = "$previous_id" ]; then
    log "latest dump already restored: $(basename "$dump_file")"
    return 0
  fi

  log "starting workflow for $dump_file"
  log "dump id: $dump_id"
  log "restore mode: $RESTORE_WORKFLOW_MODE"

  write_state_file "$dump_file" "restore" "running" "$RESTORE_STATE_DIR/restore-state.txt"

  log "phase 1: restore"
  RESTORE_MODE="$RESTORE_WORKFLOW_MODE" "$SCRIPTS_DIR/sql-benchmark-restore.sh" "$dump_file"
  local restore_rc=$?

  if [ $restore_rc -ne 0 ]; then
    log "restore failed with exit code $restore_rc"
    write_state_file "$dump_file" "restore" "failed" "$RESTORE_STATE_DIR/restore-state.txt"
    return $restore_rc
  fi

  write_state_file "$dump_file" "restore" "completed" "$RESTORE_STATE_DIR/restore-state.txt"

  if [ "$RESTORE_AUTO_BACKFILL" = "true" ]; then
    log "phase 2: backfill"
    write_state_file "$dump_file" "backfill" "running" "$RESTORE_STATE_DIR/restore-state.txt"
    "$SCRIPTS_DIR/sql-backfill-gz.sh" "$dump_file"
    local backfill_rc=$?
    if [ $backfill_rc -ne 0 ]; then
      log "backfill failed with exit code $backfill_rc"
      write_state_file "$dump_file" "backfill" "failed" "$RESTORE_STATE_DIR/restore-state.txt"
      return $backfill_rc
    fi
    write_state_file "$dump_file" "backfill" "completed" "$RESTORE_STATE_DIR/restore-state.txt"
  fi

  echo "$dump_id" > "$RESTORE_STATE_DIR/last-success.id"
  log "workflow completed successfully"
}

db_size_check() {
  local interval="${DB_SIZE_CHECK_INTERVAL:-60}"
  log "database size check every ${interval}s"
  while true; do
    sleep "$interval"
    local size_info
    size_info="$(MYSQL_PWD="$MARIADB_PASSWORD" mariadb \
      --host="$DB_HOST" \
      --port="$DB_PORT" \
      --user="$MARIADB_USER" \
      --skip-column-names \
      --batch \
      "$MARIADB_DATABASE" \
      -e "SELECT CONCAT(ROUND(SUM(DATA_LENGTH+INDEX_LENGTH)/1024/1024), ' MB') AS total, CONCAT(ROUND(SUM(DATA_LENGTH)/1024/1024), ' MB') AS data, CONCAT(ROUND(SUM(INDEX_LENGTH)/1024/1024), ' MB') AS idx, SUM(TABLE_ROWS) AS rows_count FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE();" 2>/dev/null)" || continue
    log "database size: $size_info"
  done
}

main_loop() {
  local dump_file current_id previous_id first_loop
  first_loop=true

  while true; do
    dump_file="$(find "$DUMP_WATCH_DIR" -maxdepth 1 -name '*.sql.gz' -type f -print -quit)"
    if [ -z "$dump_file" ]; then
      log "no *.sql.gz files found in $DUMP_WATCH_DIR"
      sleep "$RESTORE_POLL_INTERVAL"
      continue
    fi

    if [ "$RESTORE_ON_START" = "true" ] && [ "$first_loop" = "true" ]; then
      current_id="$(dump_id "$dump_file")"
      previous_id="$(last_success_id)"
      if [ "$current_id" != "$previous_id" ]; then
        workflow "$dump_file"
      else
        log "latest dump already restored: $(basename "$dump_file")"
      fi
      first_loop=false
      continue
    fi

    current_id="$(dump_id "$dump_file")"
    previous_id="$(last_success_id)"

    if [ "$current_id" != "$previous_id" ]; then
      log "new dump detected: $dump_file"
      local stable_file="$DUMP_WATCH_DIR/.stable-check"
      local stable_count=0
      while [ "$stable_count" -lt "$RESTORE_STABLE_SECONDS" ]; do
        sleep 1
        local new_id
        new_id="$(dump_id "$dump_file")"
        if [ "$new_id" != "$current_id" ]; then
          log "dump changed during stability check, restarting"
          current_id="$new_id"
          stable_count=0
          continue
        fi
        stable_count=$((stable_count + 1))
      done
      workflow "$dump_file"
    else
      log "latest dump already restored: $(basename "$dump_file")"
    fi

    sleep "$RESTORE_POLL_INTERVAL"
  done
}

trap release_lock EXIT INT TERM

DB_SIZE_CHECK_INTERVAL="${DB_SIZE_CHECK_INTERVAL:-60}"
db_size_check &
DB_SIZE_PID=$!
trap 'kill $DB_SIZE_PID 2>/dev/null; release_lock' EXIT INT TERM

main_loop
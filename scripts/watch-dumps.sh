#!/usr/bin/env bash
set -euo pipefail

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
    printf 'dump=%q\n' "$file"
    printf 'dump_id=%q\n' "$(dump_id "$file")"
    printf 'phase=%q\n' "$phase"
    printf 'status=%q\n' "$status"
    printf 'updated_at_utc=%q\n' "$(date -u +%FT%TZ)"
  } > "$state_file"
}

newest_dump() {
  find "$DUMP_WATCH_DIR" -maxdepth 1 -type f -name '*.sql.gz' -printf '%T@ %p\n' \
    | sort -nr \
    | awk 'NR == 1 { $1=""; sub(/^ /, ""); print }'
}

is_stable() {
  local file="$1"
  local first second

  first="$(dump_id "$file")"
  sleep "$RESTORE_STABLE_SECONDS"
  [ -f "$file" ] || return 1
  second="$(dump_id "$file")"
  [ "$first" = "$second" ]
}

acquire_lock() {
  mkdir "$RESTORE_STATE_DIR/restore.lock" 2>/dev/null
}

release_lock() {
  rmdir "$RESTORE_STATE_DIR/restore.lock" 2>/dev/null || true
}

run_restore_workflow() {
  local dump_file="$1"
  local current_id run_dir run_log started_at finished_at

  current_id="$(dump_id "$dump_file")"
  run_dir="$RESTORE_STATE_DIR/runs/$(date -u +%Y%m%dT%H%M%SZ)"
  run_log="$run_dir/worker.log"
  mkdir -p "$run_dir"

  write_state_file "$dump_file" "restore" "running" "$RESTORE_STATE_DIR/current.state"
  started_at="$(date -u +%FT%TZ)"

  {
    log "starting workflow for $dump_file"
    log "dump id: $current_id"
    log "restore mode: $RESTORE_WORKFLOW_MODE"

    if [ "$RESTORE_GZIP_TEST" = "true" ]; then
      log "testing gzip stream before restore"
      gzip -t "$dump_file"
    fi

    log "phase 1: restore"
    RESTORE_MODE="$RESTORE_WORKFLOW_MODE" "$PROJECT_DIR/scripts/sql-benchmark-restore.sh" "$dump_file"
    write_state_file "$dump_file" "backfill" "running" "$RESTORE_STATE_DIR/current.state"

    if [ "$RESTORE_AUTO_BACKFILL" = "true" ]; then
      log "phase 2: backfill"
      "$PROJECT_DIR/scripts/sql-backfill-gz.sh" "$dump_file"
    else
      log "phase 2: backfill disabled"
    fi

    finished_at="$(date -u +%FT%TZ)"
    printf '%s\n' "$current_id" > "$RESTORE_STATE_DIR/last-success.id"
    {
      printf 'dump=%q\n' "$dump_file"
      printf 'dump_id=%q\n' "$current_id"
      printf 'restore_mode=%q\n' "$RESTORE_WORKFLOW_MODE"
      printf 'auto_backfill=%q\n' "$RESTORE_AUTO_BACKFILL"
      printf 'started_at_utc=%q\n' "$started_at"
      printf 'finished_at_utc=%q\n' "$finished_at"
      printf 'status=%q\n' "success"
      printf 'log=%q\n' "$run_log"
    } > "$RESTORE_STATE_DIR/last-success.state"
    cp "$RESTORE_STATE_DIR/last-success.state" "$run_dir/success.state"
    rm -f "$RESTORE_STATE_DIR/current.state"
    log "workflow completed successfully"
  } 2>&1 | tee "$run_log"
}

main_loop() {
  local dump_file current_id previous_id first_loop
  first_loop=1

  log "watching $DUMP_WATCH_DIR for *.sql.gz"
  log "state directory: $RESTORE_STATE_DIR"

  while true; do
    dump_file="$(newest_dump || true)"
    if [ -z "$dump_file" ]; then
      log "no dump found"
      sleep "$RESTORE_POLL_INTERVAL"
      continue
    fi

    current_id="$(dump_id "$dump_file")"
    previous_id="$(last_success_id || true)"

    if [ "$current_id" = "$previous_id" ]; then
      log "latest dump already restored: $(basename "$dump_file")"
      sleep "$RESTORE_POLL_INTERVAL"
      first_loop=0
      continue
    fi

    if [ "$first_loop" = "1" ] && [ "$RESTORE_ON_START" != "true" ]; then
      log "new dump exists, but RESTORE_ON_START is disabled: $(basename "$dump_file")"
      sleep "$RESTORE_POLL_INTERVAL"
      first_loop=0
      continue
    fi

    log "candidate dump: $dump_file"
    if ! is_stable "$dump_file"; then
      log "dump is still changing, waiting"
      sleep "$RESTORE_POLL_INTERVAL"
      first_loop=0
      continue
    fi

    if ! acquire_lock; then
      log "another restore workflow is running"
      sleep "$RESTORE_POLL_INTERVAL"
      first_loop=0
      continue
    fi

    if ! run_restore_workflow "$dump_file"; then
      write_state_file "$dump_file" "workflow" "failed" "$RESTORE_STATE_DIR/last-failure.state"
      log "workflow failed for $dump_file"
    fi

    release_lock
    first_loop=0
    sleep "$RESTORE_POLL_INTERVAL"
  done
}

trap release_lock EXIT INT TERM
main_loop

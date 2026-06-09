#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-crz-opt}"
WORKSPACE_DIR="$(cd "$PROJECT_DIR/../.." && pwd)"
COMPOSE_DB_FILE="${COMPOSE_DB_FILE:-docker-compose.db.yml}"
COMPOSE_WORKER_FILE="${COMPOSE_WORKER_FILE:-docker-compose.yml}"

if command -v docker >/dev/null 2>&1; then
  COMPOSE_DB=(docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_DB_FILE")
  COMPOSE=(docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_WORKER_FILE")
elif [ -x "$WORKSPACE_DIR/scripts/nas-compose.sh" ]; then
  COMPOSE_DB=("$WORKSPACE_DIR/scripts/nas-compose.sh" "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_DB_FILE")
  COMPOSE=("$WORKSPACE_DIR/scripts/nas-compose.sh" "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_WORKER_FILE")
else
  echo "Neither docker compose nor $WORKSPACE_DIR/scripts/nas-compose.sh is available." >&2
  exit 127
fi

cd "$PROJECT_DIR"

if [ ! -f .env ]; then
  cp .env.example .env
fi

require_dump_arg() {
  if [ "${1:-}" = "" ]; then
    echo "Usage: $0 data/dumps/<dump.sql.gz>" >&2
    exit 2
  fi
}

dump_container_path() {
  local dump_file="$1"
  local abs_dump
  abs_dump="$(cd "$(dirname "$dump_file")" && pwd)/$(basename "$dump_file")"
  case "$abs_dump" in
    "$PROJECT_DIR"/data/dumps/*)
      printf '/dumps/%s\n' "${abs_dump#"$PROJECT_DIR"/data/dumps/}"
      ;;
    *)
      echo "Dump must be placed under $PROJECT_DIR/data/dumps/" >&2
      exit 2
      ;;
  esac
}

wait_for_db() {
  local attempt
  for attempt in $(seq 1 120); do
    if "${COMPOSE_DB[@]}" exec -T db /opt/crz-opt-scripts/container-wait-ready.sh >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "MariaDB did not become ready in time." >&2
  return 1
}
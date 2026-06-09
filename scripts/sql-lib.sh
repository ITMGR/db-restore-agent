#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
MARIADB_DATABASE="${MARIADB_DATABASE:-crz}"
MARIADB_ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD:-}"
RESTORE_MAX_ALLOWED_PACKET="${RESTORE_MAX_ALLOWED_PACKET:-1G}"
PRUNE_DATA_TABLE_REGEX="${PRUNE_DATA_TABLE_REGEX:-^(log_[0-9]+|counter_[0-9]+|robot_01|robot_02|elastic1)$}"

if [ -z "$MARIADB_ROOT_PASSWORD" ]; then
  echo "MARIADB_ROOT_PASSWORD is required." >&2
  exit 2
fi

sql_quote_identifier() {
  printf '`%s`' "${1//\`/\`\`}"
}

sql_quote_string() {
  printf "'%s'" "${1//\'/\'\'}"
}

require_dump_arg() {
  if [ "${1:-}" = "" ]; then
    echo "Usage: $0 data/dumps/<dump.sql.gz>" >&2
    exit 2
  fi
}

db_client() {
  MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb \
    --host="$DB_HOST" \
    --port="$DB_PORT" \
    --user=root \
    --binary-mode \
    --show-warnings \
    --max_allowed_packet="$RESTORE_MAX_ALLOWED_PACKET" \
    "$@"
}

db_client_database() {
  db_client --database="$MARIADB_DATABASE" "$@"
}

wait_for_sql_db() {
  local attempt
  for attempt in $(seq 1 120); do
    if MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb-admin ping \
      --host="$DB_HOST" \
      --port="$DB_PORT" \
      --user=root \
      --silent >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "MariaDB did not become ready at $DB_HOST:$DB_PORT in time." >&2
  return 1
}

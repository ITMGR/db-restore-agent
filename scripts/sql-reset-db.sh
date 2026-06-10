#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/sql-lib.sh"

CONFIRM="${1:-}"

if [ "$CONFIRM" != "--yes" ] && [ "${RESET_CONFIRM:-}" != "YES" ]; then
  cat >&2 <<MSG
This drops and recreates the MariaDB database:
  $MARIADB_DATABASE on $DB_HOST:$DB_PORT

Run one of:
  $0 --yes
  RESET_CONFIRM=YES $0
MSG
  exit 2
fi

wait_for_sql_db

DB_IDENT="$(sql_quote_identifier "$MARIADB_DATABASE")"

{
  printf 'DROP DATABASE IF EXISTS %s;\n' "$DB_IDENT"
  printf 'CREATE DATABASE %s CHARACTER SET utf8mb4 COLLATE utf8mb4_uca1400_ai_ci;\n' "$DB_IDENT"
} | db_client

echo "database_reset=$MARIADB_DATABASE"
#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/sql-lib.sh"

CONFIRM="${1:-}"

if [ "$CONFIRM" != "--yes" ] && [ "${RESET_CONFIRM:-}" != "YES" ]; then
  cat >&2 <<MSG
This drops all tables, triggers, procedures, functions and events
in the MariaDB database:
  $MARIADB_DATABASE on $DB_HOST:$DB_PORT

Run one of:
  $0 --yes
  RESET_CONFIRM=YES $0
MSG
  exit 2
fi

wait_for_sql_db

echo "Dropping all tables, triggers, procedures, functions and events in $MARIADB_DATABASE..."

# Drop all tables via prepared statement (no DROP DATABASE privilege needed)
db_client --database="$MARIADB_DATABASE" <<'EOSQL'
SET FOREIGN_KEY_CHECKS=0;

SET @tables = NULL;
SELECT GROUP_CONCAT(CONCAT('`', table_name, '`')) INTO @tables
FROM information_schema.tables
WHERE table_schema = DATABASE();

SET @sql = IF(@tables IS NOT NULL, CONCAT('DROP TABLE IF EXISTS ', @tables), 'SELECT 1');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SET @views = NULL;
SELECT GROUP_CONCAT(CONCAT('`', table_name, '`')) INTO @views
FROM information_schema.views
WHERE table_schema = DATABASE();

SET @sql = IF(@views IS NOT NULL, CONCAT('DROP VIEW IF EXISTS ', @views), 'SELECT 1');
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SET FOREIGN_KEY_CHECKS=1;
EOSQL

# Drop triggers
db_client --database="$MARIADB_DATABASE" -e "
SELECT CONCAT('DROP TRIGGER IF EXISTS \`', TRIGGER_NAME, '\`;')
FROM information_schema.TRIGGERS
WHERE TRIGGER_SCHEMA = DATABASE();" --skip-column-names --batch \
  | db_client --database="$MARIADB_DATABASE" 2>/dev/null || true

# Drop procedures
db_client --database="$MARIADB_DATABASE" -e "
SELECT CONCAT('DROP PROCEDURE IF EXISTS \`', ROUTINE_NAME, '\`;')
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = DATABASE() AND ROUTINE_TYPE = 'PROCEDURE';" --skip-column-names --batch \
  | db_client --database="$MARIADB_DATABASE" 2>/dev/null || true

# Drop functions
db_client --database="$MARIADB_DATABASE" -e "
SELECT CONCAT('DROP FUNCTION IF EXISTS \`', ROUTINE_NAME, '\`;')
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = DATABASE() AND ROUTINE_TYPE = 'FUNCTION';" --skip-column-names --batch \
  | db_client --database="$MARIADB_DATABASE" 2>/dev/null || true

# Drop events
db_client --database="$MARIADB_DATABASE" -e "
SELECT CONCAT('DROP EVENT IF EXISTS \`', EVENT_NAME, '\`;')
FROM information_schema.EVENTS
WHERE EVENT_SCHEMA = DATABASE();" --skip-column-names --batch \
  | db_client --database="$MARIADB_DATABASE" 2>/dev/null || true

echo "database_reset=$MARIADB_DATABASE (all objects dropped)"
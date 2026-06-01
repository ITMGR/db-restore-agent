#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"

CONFIRM="${1:-}"

if [ "$CONFIRM" != "--yes" ] && [ "${RESET_CONFIRM:-}" != "YES" ]; then
  cat >&2 <<MSG
This deletes the local MariaDB data directory:
  $PROJECT_DIR/data/mariadb

Run one of:
  $0 --yes
  RESET_CONFIRM=YES $0
MSG
  exit 2
fi

"${COMPOSE[@]}" stop db >/dev/null 2>&1 || true
"${COMPOSE[@]}" rm -f db >/dev/null 2>&1 || true
rm -rf "$PROJECT_DIR/data/mariadb"
"${COMPOSE[@]}" up -d db
wait_for_db
"${COMPOSE[@]}" ps db

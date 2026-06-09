#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"

CONFIRM="${1:-}"

if [ "$CONFIRM" != "--yes" ] && [ "${RESET_CONFIRM:-}" != "YES" ]; then
  cat >&2 <<MSG
This deletes the MariaDB Docker volume data:
  crz-opt-mariadb-data

Run one of:
  $0 --yes
  RESET_CONFIRM=YES $0
MSG
  exit 2
fi

"${COMPOSE_DB[@]}" stop db >/dev/null 2>&1 || true
"${COMPOSE_DB[@]}" rm -f db >/dev/null 2>&1 || true
"${COMPOSE_DB[@]}" run --rm --no-deps --entrypoint sh -v crz-opt-mariadb-data:/target db -c 'find /target -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +'
"${COMPOSE_DB[@]}" up -d db
wait_for_db
"${COMPOSE_DB[@]}" ps db
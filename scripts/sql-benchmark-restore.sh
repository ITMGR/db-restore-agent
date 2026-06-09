#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/sql-lib.sh"

require_dump_arg "${1:-}"

DUMP_FILE="$1"
MODE="${RESTORE_MODE:-baseline}"

"$PROJECT_DIR/scripts/sql-reset-db.sh" --yes
RESTORE_MODE="$MODE" "$PROJECT_DIR/scripts/sql-restore-gz.sh" "$DUMP_FILE"

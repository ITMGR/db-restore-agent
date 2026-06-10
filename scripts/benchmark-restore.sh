#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

require_dump_arg "${1:-}"

DUMP_FILE="$1"
MODE="${RESTORE_MODE:-baseline}"

"$SCRIPTS_DIR/reset-db.sh" --yes
RESTORE_MODE="$MODE" "$SCRIPTS_DIR/restore-gz.sh" "$DUMP_FILE"

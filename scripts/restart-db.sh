#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"

"${COMPOSE_DB[@]}" restart db
wait_for_db
"${COMPOSE_DB[@]}" ps db
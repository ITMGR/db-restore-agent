#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"

"${COMPOSE[@]}" up -d db
wait_for_db
"${COMPOSE[@]}" ps db

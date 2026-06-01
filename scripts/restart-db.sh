#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/lib.sh"

"${COMPOSE[@]}" restart db
wait_for_db
"${COMPOSE[@]}" ps db

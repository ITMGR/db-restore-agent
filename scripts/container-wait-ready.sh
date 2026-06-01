#!/usr/bin/env sh
set -eu

exec mariadb-admin ping \
  -h 127.0.0.1 \
  -uroot \
  -p"${MARIADB_ROOT_PASSWORD}" \
  --silent

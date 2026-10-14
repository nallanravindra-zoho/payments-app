#!/usr/bin/env bash
# (Re)creates the e2e database: shim + migrations + seed, with a fixed "today" so screens match the prototype (14 Oct 2026).
set -euo pipefail
DB=${PGDATABASE:-classpay_e2e}
cd "$(dirname "$0")/../../../supabase"
export PGUSER=${PGUSER:-postgres}
psql -q -d postgres -c "drop database if exists $DB" -c "create database $DB"
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f tests/shim.sql
for f in migrations/*.sql; do psql -q -v ON_ERROR_STOP=1 -d "$DB" -f "$f" >/dev/null; done
psql -q -d "$DB" -c "alter database $DB set app.today = '${TEST_TODAY:-2026-10-14}'"
psql -q -v ON_ERROR_STOP=1 -d "$DB" -f seed.sql
echo "e2e database ready: $DB"

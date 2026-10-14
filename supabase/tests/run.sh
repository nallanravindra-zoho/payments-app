#!/usr/bin/env bash
# Apply shim + migrations (+ seed) to a throwaway local database and run SQL tests.
# Usage: supabase/tests/run.sh [dbname]   (needs a local postgres reachable via PGHOST/PGUSER, default: postgres user on localhost socket)
set -euo pipefail
DB=${1:-classpay_test}
cd "$(dirname "$0")/.."
export PGUSER=${PGUSER:-postgres}
psql -v ON_ERROR_STOP=1 -q -d postgres -c "drop database if exists $DB" -c "create database $DB"
psql -v ON_ERROR_STOP=1 -q -d "$DB" -f tests/shim.sql
for f in migrations/*.sql; do echo "== $f"; psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$f"; done
if [ "${SEED:-0}" = "1" ]; then psql -v ON_ERROR_STOP=1 -q -d "$DB" -f seed.sql; fi
for t in tests/*_test.sql; do [ -e "$t" ] || continue; echo "== test $t"; psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$t"; done
echo "ALL SQL OK"

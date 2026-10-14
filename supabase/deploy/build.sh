#!/usr/bin/env bash
# Rebuilds supabase/deploy/all_migrations.sql from supabase/migrations (for the dashboard SQL editor).
cd "$(dirname "$0")/../.."
{ echo "-- ClassPay: all migrations in order. Paste into Supabase Dashboard > SQL Editor > New query > Run (once)."; for f in supabase/migrations/*.sql; do echo; echo "-- ===== $(basename "$f") ====="; cat "$f"; done; } > supabase/deploy/all_migrations.sql

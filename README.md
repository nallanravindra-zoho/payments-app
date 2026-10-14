# ClassPay

Classes, fees and receipts for independent teachers and academies (India). A mobile-first **PWA on Supabase**: React + TypeScript front end,
PostgreSQL (RLS + SQL functions) for every money rule, edge functions for payment-provider calls. No always-on server.

| Folder | What it is |
|---|---|
| `web/` | The PWA (Vite, React, TypeScript, installable, service worker). UI is a port of the approved 58-screen prototype (`prototype-v3/`). |
| `supabase/` | Migrations, `seed.sql`, edge functions (`create-payment`, `submit-proof`, `payment-webhook`, `mock-provider`), `config.toml`, SQL tests. |
| `docs/` | Requirements and design (`REQUIREMENTS_AND_DESIGN.md`), implementation notes (`IMPLEMENTATION.md`). |
| `prototype-v3/` | The approved clickable prototype the UI was built from (reference only). |

## Run it locally (with the Supabase CLI + Docker)

```bash
supabase start                    # Postgres, Auth, Storage, Edge runtime
supabase db reset                 # applies supabase/migrations + supabase/seed.sql (demo academy)
supabase functions serve --no-verify-jwt   # edge functions
cd web && cp .env.example .env.local      # fill VITE_SUPABASE_ANON_KEY from `supabase status`; set VITE_DEMO_MODE=true for demo hints
npm install && npm run dev
```

Demo sign-ins (test OTP `123456`, configured in `supabase/config.toml`): owner **9876543210**, teacher Rahul **9000000002**, parent Neha Sharma **9000000003**.
Student portal invitation codes: `CP-STU-DEMO0001` (Aarav, under 18) and `CP-STU-DEMO0002` (Ishaan, adult). Open the app, enter the phone, choose a role.

## Tests

```bash
supabase/tests/run.sh             # SQL: applies migrations to a throw-away Postgres and runs lifecycle + portal tests (needs a local postgres)
cd web && npm run typecheck
CHROMIUM_PATH=/path/to/chromium npm run test:e2e   # builds the PWA and drives every role against the local harness (real SQL + RLS)
```

The e2e **harness** (`web/e2e/harness/`) emulates only the Supabase *transport* (phone-OTP auth with a fixed code, PostgREST-style RPC,
storage, function hosting) so tests run without Docker. All SQL, RLS, GRANTs and edge-function handlers under test are the real ones.
It is a test tool and is never deployed.

## Going to production

See `docs/IMPLEMENTATION.md` (checklist: phone auth provider, payment-provider secrets, webhook URL, storage bucket, cron, backups, DPDP review).

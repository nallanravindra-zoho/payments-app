# Implementation notes

Status: **first build** of the Supabase PWA against `REQUIREMENTS_AND_DESIGN.md` v0.5 and the 58-screen prototype. Verified here with SQL tests and
Playwright end-to-end tests against a local harness (not against a hosted Supabase project, a real SMS provider, or a real payment gateway).

## Architecture

```
PWA (React) ──supabase-js──► Auth (phone OTP) · PostgREST RPC · Storage (private "proofs") · Edge Functions
                                         │                                   │
                                  PostgreSQL: tables + RLS + SECURITY DEFINER functions      create-payment · submit-proof · payment-webhook · mock-provider
```

* **Every write goes through a SQL function.** Tables are read-only to clients and protected by RLS (tenant, role, guardian link, student link).
  Invoices are immutable (trigger); allocations are append-only and cannot exceed verified money or an invoice balance (trigger); receipts are never
  deleted (reversal creates a linked correction); recurring billing is idempotent per enrolment + period.
* **Roles come from the database**, never from a client flag: `memberships` (owner/admin/accountant/teacher), `guardians` (parent), `student_accounts` (student).
  Invited staff/guardians claim their row by **verified email** at first sign-in (`my_context`; the address must be confirmed in Supabase Auth). Minors cannot reach billing; adult students only their own invoices.
* **Money truth.** A browser redirect never marks anything paid. Gateway success arrives as a **signed webhook** → `svc_gateway_event` (idempotent by event id,
  amount-checked, order-safe). A direct-UPI screenshot is *evidence*: the owner must confirm the bank credit before `approve_payment` succeeds; duplicate UTRs are flagged.
* **No-install parents** use a high-entropy, hashed, expiring, revocable fee link (`/pay/<token>`); the token is the only credential for the anonymous RPCs.
* **Calendars (Day/Week/Month)** are client views over one bounded, role-scoped RPC (`calendar_range`, ≤ 62 days) enforced in SQL.

## Differences from the prototype (deliberate)

The UI is a faithful port (same copy, layout, tokens, navigation). Changes are limited to what real data/security required:

1. **Sign-in is email + password** (the prototype showed phone OTP). Demo-only text ("Simulate…") appears only with `VITE_DEMO_MODE=true` / mock provider. Phone/SMS login can be added later.
2. **Role screen** is validated server-side: choosing a role you have no membership for explains why (or starts academy creation for a new owner).
3. **Added fields/controls that real operation needs:** owner name on first academy setup; teacher email and room on *Create batch*; guardian email on *Add a student*; invoice checkboxes on *Family bill*;
   a bank-credit confirmation checkbox on *Verify payment*; duplicate-row decision + preview on *Import*; payment settings and tax settings cards; student list; a
   *Copy parent fee link* / *Invite student to portal* action on the student profile; sign-out and role switching.
4. **Screens that showed another role's screen** (e.g. owner rejecting a proof landing on the parent "Payment not confirmed" screen) return to the owner's inbox instead.
5. **Numbers are computed**, not illustrative; the seed reproduces the prototype's headline figures (₹78,000 collected, ₹18,500 overdue across 5 families, 3 proofs, 82 active students).

## Known gaps / not built yet

* Real SMS/WhatsApp/email delivery (`notification_outbox` is written; no sender yet). Reminders are queued by `app.queue_reminders()` (cadence −3/0/+1/+7/+14 days; suppressed for promises, pending proofs, holds).
* Payment gateway: Razorpay order creation + signature verification are implemented against the documented API but **untested against a live account**; set secrets and verify in sandbox.
* Bank CSV import, trial→paid conversion UI, expenses UI (batch costs are DB-only), announcements UI (DB/RPC only), session cancel/reschedule UI for owners, GST filing exports beyond CSV.
* Offline: shell is cached; data screens show an offline banner and payment actions are blocked (no offline mutation queue by design).
* DPDP/consent review for minors' data and a threat-model pass before taking real money.

## Production checklist

1. Supabase project (India region). Auth → Providers → **Email** enabled with **Confirm email ON**; set Site URL and add redirect URLs `<site>/login` and `<site>/reset`; configure custom SMTP before launch (the built-in mailer is rate-limited).
2. Secrets: `PAYMENT_PROVIDER=razorpay`, `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`, `RAZORPAY_WEBHOOK_SECRET`; deploy functions; set the provider webhook to `/functions/v1/payment-webhook` (events `payment.captured`, `order.paid`, `payment.failed`).
3. Web env: `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_PAYMENT_PROVIDER=razorpay`, `VITE_RAZORPAY_KEY_ID`; `VITE_DEMO_MODE` unset.
4. Run migrations (not `seed.sql`). Confirm `pg_cron` created job `classpay-daily` (01:00 IST: billing, sessions, promises, reminders).
5. Enable backups/PITR, usage alerts, rate limits; rotate keys; never ship the service-role key to the client.

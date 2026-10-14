-- ClassPay: all migrations in order. Paste into Supabase Dashboard > SQL Editor > New query > Run (once).
-- Generated from supabase/migrations/*.sql — do not edit by hand (run supabase/deploy/build.sh).

-- ===== 20261014000001_core_schema.sql =====
-- ClassPay core schema (PostgreSQL / Supabase)
-- Principles (requirements §16, §20): tenant-scoped rows, RLS as defence in depth,
-- every money mutation goes through a SECURITY DEFINER function, issued documents are immutable.

create schema if not exists app;

-- ---------------------------------------------------------------- helpers
create or replace function app.today() returns date language sql stable as $$
  select coalesce(nullif(current_setting('app.today', true), '')::date, (now() at time zone 'Asia/Kolkata')::date)
$$;
create or replace function app.norm_phone(p text) returns text language sql immutable as $$
  select nullif(right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10), '')
$$;
create or replace function app.my_phone() returns text language sql stable as $$
  select app.norm_phone(auth.jwt() ->> 'phone')
$$;

-- ---------------------------------------------------------------- tenants & people
create table public.institutes (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null default 'Music / Dance / Coaching',
  city_state text,
  phone text,
  gst_configured boolean not null default false,
  gst_registered boolean not null default false,
  gstin text,
  gst_rate numeric(5,2) not null default 18,
  prices_include_gst boolean not null default true,
  filing_frequency text not null default 'quarterly' check (filing_frequency in ('monthly','quarterly','yearly')),
  gst_threshold numeric(14,2) not null default 2000000,
  upi_vpa text,
  gateway_enabled boolean not null default false,
  direct_upi_enabled boolean not null default true,
  passthrough_fee boolean not null default false,
  default_fee numeric(12,2) not null default 2000,
  logo_path text,
  created_by uuid,
  created_at timestamptz not null default now()
);

create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  user_id uuid,
  role text not null check (role in ('owner','admin','teacher','accountant')),
  display_name text,
  phone text,                              -- normalised 10 digits; lets an invited user claim the row on first login
  status text not null default 'active' check (status in ('active','invited','revoked')),
  created_at timestamptz not null default now()
);
create unique index memberships_user_uq on public.memberships (institute_id, user_id) where user_id is not null;
create index memberships_user_ix on public.memberships (user_id);

create table public.families (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  label text not null,
  import_id uuid,
  created_at timestamptz not null default now()
);
create index families_inst_ix on public.families (institute_id);

create table public.guardians (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  family_id uuid not null references public.families on delete cascade,
  name text not null,
  phone text,                              -- normalised
  email text,
  user_id uuid,
  relationship text,
  is_billing_contact boolean not null default true,
  import_id uuid,
  created_at timestamptz not null default now()
);
create index guardians_family_ix on public.guardians (family_id);
create index guardians_phone_ix on public.guardians (institute_id, phone);
create index guardians_user_ix on public.guardians (user_id);

create table public.students (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  family_id uuid not null references public.families on delete cascade,
  name text not null,
  age_group text not null default 'minor' check (age_group in ('minor','adult')),
  status text not null default 'active' check (status in ('trial','active','paused','dropped')),
  status_reason text,
  converted_on date,
  joined_on date not null default app.today(),
  import_id uuid,
  created_at timestamptz not null default now()
);
create index students_family_ix on public.students (family_id);
create index students_inst_ix on public.students (institute_id, status);

-- ---------------------------------------------------------------- teaching
create table public.batches (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  name text not null,
  subject text,
  level text,
  room text,
  teacher_membership_id uuid references public.memberships,
  capacity int not null default 15 check (capacity > 0),
  weekly_slots jsonb not null default '[]',       -- [{"dow":1,"start":"17:00","end":"18:00"}]
  base_fee numeric(12,2) not null default 0,
  start_on date not null default app.today(),
  end_on date,
  status text not null default 'active' check (status in ('active','archived')),
  created_at timestamptz not null default now()
);
create index batches_inst_ix on public.batches (institute_id);

create table public.enrollments (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  student_id uuid not null references public.students on delete cascade,
  batch_id uuid not null references public.batches on delete cascade,
  start_on date not null,
  end_on date,
  custom_slot text,
  status text not null default 'active' check (status in ('active','ended')),
  fee_model text not null default 'per_student' check (fee_model in ('per_student','per_batch_split','class_pack')),
  frequency text not null default 'monthly' check (frequency in ('monthly','quarterly','term','one_time')),
  base_fee numeric(12,2) not null,
  discount_label text,
  discount_amount numeric(12,2) not null default 0,
  billing_day int not null default 5 check (billing_day between 1 and 28),
  last_billed_period text,                          -- period key, e.g. '2026-10' / '2026-Q4' – generation is idempotent per period
  import_id uuid,
  created_at timestamptz not null default now()
);
create unique index enrollments_active_uq on public.enrollments (student_id, batch_id) where status = 'active';
create index enrollments_batch_ix on public.enrollments (batch_id) where status = 'active';

create table public.class_sessions (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  batch_id uuid not null references public.batches on delete cascade,
  teacher_membership_id uuid references public.memberships,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  room text,
  status text not null default 'scheduled' check (status in ('scheduled','cancelled','rescheduled','done')),
  is_makeup boolean not null default false,
  original_session_id uuid references public.class_sessions,
  original_starts_at timestamptz,
  updated_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (batch_id, starts_at)
);
create index sessions_inst_ix on public.class_sessions (institute_id, starts_at);
create index sessions_teacher_ix on public.class_sessions (teacher_membership_id, starts_at);

create table public.attendance (
  session_id uuid not null references public.class_sessions on delete cascade,
  student_id uuid not null references public.students on delete cascade,
  status text not null check (status in ('present','absent','late')),
  marked_by uuid,
  marked_at timestamptz not null default now(),
  primary key (session_id, student_id)
);
create table public.attendance_history (
  id bigserial primary key,
  session_id uuid not null,
  student_id uuid not null,
  old_status text,
  new_status text not null,
  changed_by uuid,
  changed_at timestamptz not null default now()
);
create table public.lesson_credits (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  student_id uuid not null references public.students on delete cascade,
  enrollment_id uuid references public.enrollments on delete set null,
  reason text not null check (reason in ('Teacher cancelled','Approved absence','Holiday adjustment')),
  origin_session_id uuid references public.class_sessions on delete set null,
  request_id uuid,
  expires_on date not null,
  state text not null default 'open' check (state in ('open','redeemed','expired')),
  redeemed_session_id uuid references public.class_sessions,
  redeemed_at timestamptz,
  issued_by uuid,
  created_at timestamptz not null default now()
);
create unique index lesson_credits_origin_uq on public.lesson_credits (student_id, origin_session_id) where origin_session_id is not null;   -- no duplicate credit per cancelled class
create index lesson_credits_student_ix on public.lesson_credits (student_id) where state = 'open';

create table public.makeup_requests (                -- student/guardian request; staff review decides, never auto-credits (§26.6)
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  student_id uuid not null references public.students on delete cascade,
  enrollment_id uuid references public.enrollments on delete set null,
  session_id uuid references public.class_sessions on delete set null,
  reason text,
  status text not null default 'requested' check (status in ('requested','approved','declined')),
  requested_by uuid,
  requested_at timestamptz not null default now(),
  reviewed_by uuid,
  reviewed_at timestamptz
);
create unique index makeup_open_uq on public.makeup_requests (student_id, coalesce(session_id, '00000000-0000-0000-0000-000000000000'::uuid)) where status = 'requested';

create table public.student_invites (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  student_id uuid not null references public.students on delete cascade,
  code_hash text not null unique,
  expires_at timestamptz not null,
  used_at timestamptz,
  revoked_at timestamptz,
  issued_by uuid,
  created_at timestamptz not null default now()
);
create table public.student_accounts (               -- links an auth user to a student record (server-side only)
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  student_id uuid not null references public.students on delete cascade,
  user_id uuid not null,
  display_name text,
  class_reminders boolean not null default true,
  language text not null default 'en',
  activated_at timestamptz not null default now(),
  revoked_at timestamptz
);
create unique index student_accounts_uq on public.student_accounts (student_id) where revoked_at is null;
create index student_accounts_user_ix on public.student_accounts (user_id) where revoked_at is null;

create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  batch_id uuid references public.batches on delete cascade,   -- null = whole academy
  title text not null,
  body text,
  published_at timestamptz not null default now(),
  created_by uuid
);
create index announcements_inst_ix on public.announcements (institute_id, published_at desc);

-- ---------------------------------------------------------------- billing
create table public.counters (
  institute_id uuid not null references public.institutes on delete cascade,
  kind text not null,
  year int not null,
  value int not null default 0,
  primary key (institute_id, kind, year)
);

create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  family_id uuid not null references public.families,
  student_id uuid references public.students,
  enrollment_id uuid references public.enrollments,
  batch_id uuid references public.batches,
  invoice_number text not null,
  period text,
  issued_on date not null default app.today(),
  due_on date not null,
  state text not null default 'issued' check (state in ('issued','void')),
  source text not null default 'issued' check (source in ('issued','imported','cron')),
  subtotal numeric(12,2) not null,
  discount numeric(12,2) not null default 0,
  tax_total numeric(12,2) not null default 0,
  grand_total numeric(12,2) not null check (grand_total >= 0),
  tax_snapshot jsonb not null default '{}',
  import_id uuid,
  created_by uuid,
  created_at timestamptz not null default now(),
  unique (institute_id, invoice_number)
);
create unique index invoices_period_uq on public.invoices (enrollment_id, period) where enrollment_id is not null and period is not null and state = 'issued';
create index invoices_family_ix on public.invoices (family_id);
create index invoices_due_ix on public.invoices (institute_id, due_on);

create table public.invoice_lines (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices on delete cascade,
  description text not null,
  service_period text,
  quantity numeric(10,2) not null default 1,
  unit_amount numeric(12,2) not null,
  discount numeric(12,2) not null default 0,
  tax_rate numeric(5,2) not null default 0,
  taxable_amount numeric(12,2) not null,
  total numeric(12,2) not null
);
create index invoice_lines_inv_ix on public.invoice_lines (invoice_id);

create table public.invoice_adjustments (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.invoices on delete cascade,
  kind text not null check (kind in ('credit_note','writeoff')),
  amount numeric(12,2) not null check (amount > 0),
  reason text not null,
  authorized_by uuid,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- money in
create table public.payments (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  family_id uuid not null references public.families,
  payer_guardian_id uuid references public.guardians,
  channel text not null check (channel in ('gateway','direct_upi','cash','bank','cheque','credit')),
  method text,                                       -- 'UPI','Card','Netbanking','Cash',...
  state text not null check (state in ('initiated','pending_provider','failed','expired','cancelled','pending_manual_review','needs_clarification','verified','rejected','reversed','refunded')),
  claimed_amount numeric(12,2) not null check (claimed_amount >= 0),
  verified_amount numeric(12,2),
  reference text,                                     -- UTR / provider payment id
  paid_on date,
  attempt_ref text,                                   -- PAY-42017
  provider text,
  provider_order_id text,
  idempotency_key text,
  bank_match_status text not null default 'unconfirmed' check (bank_match_status in ('unconfirmed','confirmed','mismatch')),
  duplicate_of uuid references public.payments,
  collector text,
  note text,
  reason text,
  recorded_by uuid,
  verified_by uuid,
  verified_at timestamptz,
  import_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index payments_attempt_uq on public.payments (institute_id, attempt_ref) where attempt_ref is not null;
create unique index payments_order_uq on public.payments (provider, provider_order_id) where provider_order_id is not null;
create unique index payments_idem_uq on public.payments (institute_id, idempotency_key) where idempotency_key is not null;
create index payments_family_ix on public.payments (family_id);
create index payments_ref_ix on public.payments (institute_id, reference) where reference is not null;

create table public.payment_invoices (               -- which invoices a pending payment is meant for
  payment_id uuid not null references public.payments on delete cascade,
  invoice_id uuid not null references public.invoices,
  claimed_amount numeric(12,2) not null,
  primary key (payment_id, invoice_id)
);

create table public.payment_allocations (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments,
  invoice_id uuid not null references public.invoices,
  amount numeric(12,2) not null check (amount > 0),
  applied_at timestamptz not null default now(),
  applied_by uuid
);
create index alloc_payment_ix on public.payment_allocations (payment_id);
create index alloc_invoice_ix on public.payment_allocations (invoice_id);

create table public.payment_proofs (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.payments on delete cascade,
  file_path text,
  submitted_by uuid,
  submitted_at timestamptz not null default now(),
  review_state text not null default 'pending' check (review_state in ('pending','approved','rejected','clarification')),
  reviewed_by uuid,
  reviewed_at timestamptz,
  reviewer_note text
);

create table public.receipts (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  payment_id uuid not null references public.payments,
  family_id uuid not null references public.families,
  receipt_number text not null,
  issued_on date not null default app.today(),
  amount numeric(12,2) not null,
  snapshot jsonb not null,
  status text not null default 'valid' check (status in ('valid','reversed')),
  correction_ref text,
  sent_via text[],
  created_at timestamptz not null default now(),
  unique (institute_id, receipt_number)
);

-- ---------------------------------------------------------------- collections
create table public.collection_cases (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  family_id uuid not null references public.families,
  invoice_id uuid references public.invoices,
  type text not null check (type in ('promise','dispute','hold')),
  state text not null default 'open' check (state in ('open','kept','missed','resolved')),
  promise_date date,
  promised_amount numeric(12,2),
  channel text,
  reason text,
  owner_id uuid,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);
create index cases_family_ix on public.collection_cases (family_id) where state = 'open';

create table public.fee_links (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  family_id uuid not null references public.families on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  last_used_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now()
);

create table public.notification_outbox (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  family_id uuid references public.families,
  template text not null,
  channel text not null,
  status text not null default 'queued' check (status in ('queued','sent','failed','suppressed')),
  payload jsonb not null default '{}',
  scheduled_at timestamptz not null default now(),
  sent_at timestamptz,
  attempts int not null default 0,
  last_error text,
  dedupe_key text,
  created_at timestamptz not null default now()
);
create unique index outbox_dedupe_uq on public.notification_outbox (institute_id, dedupe_key) where dedupe_key is not null;

-- ---------------------------------------------------------------- reporting inputs, imports, audit
create table public.batch_costs (
  batch_id uuid not null references public.batches on delete cascade,
  month date not null,
  teacher_cost numeric(12,2) not null default 0,
  room_materials_cost numeric(12,2) not null default 0,
  primary key (batch_id, month)
);
create table public.targets (
  institute_id uuid not null references public.institutes on delete cascade,
  period_start date not null,
  amount numeric(14,2) not null,
  primary key (institute_id, period_start)
);
create table public.import_batches (
  id uuid primary key default gen_random_uuid(),
  institute_id uuid not null references public.institutes on delete cascade,
  source_name text,
  state text not null default 'preview' check (state in ('preview','committed','reverted')),
  rows jsonb not null default '[]',
  summary jsonb not null default '{}',
  created_by uuid,
  created_at timestamptz not null default now(),
  committed_at timestamptz,
  reverted_at timestamptz
);
create table public.webhook_events (
  provider text not null,
  event_id text not null,
  payload jsonb,
  received_at timestamptz not null default now(),
  primary key (provider, event_id)
);
create table public.audit_events (
  id bigserial primary key,
  institute_id uuid,
  actor uuid,
  entity text not null,
  entity_id text,
  event_type text not null,
  before jsonb,
  after jsonb,
  created_at timestamptz not null default now()
);
create index audit_inst_ix on public.audit_events (institute_id, created_at desc);

-- ---------------------------------------------------------------- invariants (triggers)
-- Issued invoices and their lines are immutable except for voiding.
create or replace function app.guard_invoice() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if coalesce(current_setting('app.allow_invoice_delete', true), '') <> 'on' then
      raise exception 'invoices_are_immutable' using errcode = 'P0001';
    end if;
    return old;
  end if;
  if (new.subtotal, new.discount, new.tax_total, new.grand_total, new.tax_snapshot, new.invoice_number, new.family_id, new.due_on)
     is distinct from
     (old.subtotal, old.discount, old.tax_total, old.grand_total, old.tax_snapshot, old.invoice_number, old.family_id, old.due_on) then
    raise exception 'invoices_are_immutable' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger invoices_guard before update or delete on public.invoices for each row execute function app.guard_invoice();

create or replace function app.guard_invoice_line() returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('app.allow_invoice_delete', true), '') = 'on' and tg_op = 'DELETE' then return old; end if;
  raise exception 'invoice_lines_are_immutable' using errcode = 'P0001';
end $$;
create trigger invoice_lines_guard before update or delete on public.invoice_lines for each row execute function app.guard_invoice_line();

-- Allocation may never exceed verified money nor the invoice balance (invariant 1, 2).
create or replace function app.guard_allocation() returns trigger language plpgsql as $$
declare v_ver numeric; v_state text; v_alloc numeric; v_total numeric; v_paid numeric; v_adj numeric; v_fam_p uuid; v_fam_i uuid;
begin
  select verified_amount, state, family_id into v_ver, v_state, v_fam_p from payments where id = new.payment_id for update;
  if v_state is distinct from 'verified' then raise exception 'payment_not_verified' using errcode = 'P0001'; end if;
  select grand_total, family_id into v_total, v_fam_i from invoices where id = new.invoice_id for update;
  if v_fam_p <> v_fam_i then raise exception 'cross_family_allocation' using errcode = 'P0001'; end if;
  select coalesce(sum(amount),0) into v_alloc from payment_allocations where payment_id = new.payment_id and id <> new.id;
  if v_alloc + new.amount > coalesce(v_ver,0) then raise exception 'allocation_exceeds_verified_amount' using errcode = 'P0001'; end if;
  select coalesce(sum(a.amount),0) into v_paid from payment_allocations a join payments p on p.id = a.payment_id where a.invoice_id = new.invoice_id and p.state = 'verified' and a.id <> new.id;
  select coalesce(sum(amount),0) into v_adj from invoice_adjustments where invoice_id = new.invoice_id;
  if v_paid + v_adj + new.amount > v_total then raise exception 'allocation_exceeds_invoice_balance' using errcode = 'P0001'; end if;
  return new;
end $$;
create trigger allocation_guard before insert on public.payment_allocations for each row execute function app.guard_allocation();

create or replace function app.guard_alloc_immutable() returns trigger language plpgsql as $$
begin raise exception 'allocations_are_immutable' using errcode = 'P0001'; end $$;
create trigger allocation_immutable before update or delete on public.payment_allocations for each row execute function app.guard_alloc_immutable();

create or replace function app.touch_payment() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
create trigger payments_touch before update on public.payments for each row execute function app.touch_payment();

-- ===== 20261014000002_rls_and_helpers.sql =====
-- Row Level Security + access helpers.
-- All WRITES go through SECURITY DEFINER functions (later migrations); direct table access is read-only and scoped.

create or replace function app.is_role(p_inst uuid, p_roles text[]) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select exists (select 1 from memberships m
                 where m.institute_id = p_inst and m.user_id = auth.uid() and m.status = 'active' and m.role = any (p_roles))
$$;
create or replace function app.is_finance(p_inst uuid) returns boolean language sql stable as $$
  select app.is_role(p_inst, array['owner','admin','accountant'])
$$;
create or replace function app.my_family_ids() returns setof uuid
language sql stable security definer set search_path = public, app, pg_temp as $$
  select family_id from guardians where user_id = auth.uid()
$$;

do $$
declare t text;
begin
  foreach t in array array['institutes','memberships','families','guardians','students','batches','enrollments','class_sessions','attendance','attendance_history',
    'lesson_credits','makeup_requests','student_invites','student_accounts','announcements','counters','invoices','invoice_lines','invoice_adjustments','payments','payment_invoices','payment_allocations','payment_proofs','receipts',
    'collection_cases','fee_links','notification_outbox','batch_costs','targets','import_batches','webhook_events','audit_events']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- Staff with finance roles read everything in their institute.
do $$
declare t text;
begin
  foreach t in array array['families','guardians','students','batches','enrollments','class_sessions','lesson_credits','makeup_requests','announcements','invoices','payments','receipts',
    'collection_cases','notification_outbox','import_batches']
  loop
    execute format('grant select on public.%I to authenticated', t);
    execute format($p$create policy %I on public.%I for select to authenticated using (app.is_finance(institute_id))$p$, t || '_finance_read', t);
  end loop;
end $$;

-- institutes / memberships
grant select on public.institutes, public.memberships to authenticated;
create policy institutes_member_read on public.institutes for select to authenticated using (app.is_role(id, array['owner','admin','teacher','accountant']) or id in (select institute_id from public.families where id in (select app.my_family_ids())));
create policy memberships_read on public.memberships for select to authenticated using (user_id = auth.uid() or app.is_finance(institute_id));

-- tables without institute_id column
grant select on public.invoice_adjustments, public.lesson_credits, public.makeup_requests, public.announcements, public.invoice_lines, public.payment_allocations, public.payment_invoices, public.payment_proofs, public.attendance to authenticated;
create policy adj_finance_read on public.invoice_adjustments for select to authenticated using (exists (select 1 from public.invoices i where i.id = invoice_id and app.is_finance(i.institute_id)));
create policy lines_finance_read on public.invoice_lines for select to authenticated using (exists (select 1 from public.invoices i where i.id = invoice_id and app.is_finance(i.institute_id)));
create policy alloc_finance_read on public.payment_allocations for select to authenticated using (exists (select 1 from public.payments p where p.id = payment_id and app.is_finance(p.institute_id)));
create policy pinv_finance_read on public.payment_invoices for select to authenticated using (exists (select 1 from public.payments p where p.id = payment_id and app.is_finance(p.institute_id)));
create policy proofs_finance_read on public.payment_proofs for select to authenticated using (exists (select 1 from public.payments p where p.id = payment_id and app.is_finance(p.institute_id)));
create policy attendance_staff_read on public.attendance for select to authenticated using (exists (select 1 from public.class_sessions s where s.id = session_id and app.is_role(s.institute_id, array['owner','admin','teacher'])));

-- Teachers: only sessions (no fee data anywhere) – everything else through teacher RPCs.
create policy sessions_teacher_read on public.class_sessions for select to authenticated using (
  teacher_membership_id in (select id from public.memberships where user_id = auth.uid() and role = 'teacher' and status = 'active'));

-- Students: only their own linked records. Money tables stay closed to minors; adult self-billing goes through RPCs.
create or replace function app.my_student_ids() returns setof uuid
language sql stable security definer set search_path = public, app, pg_temp as $$
  select student_id from student_accounts where user_id = auth.uid() and revoked_at is null
$$;
grant select on public.student_accounts to authenticated;
create policy student_accounts_self on public.student_accounts for select to authenticated using (user_id = auth.uid() and revoked_at is null);
create policy students_self_read on public.students for select to authenticated using (id in (select app.my_student_ids()));
create or replace function app.my_batch_ids() returns setof uuid
language sql stable security definer set search_path = public, app, pg_temp as $$
  select e.batch_id from enrollments e
   where e.status = 'active' and (e.student_id in (select student_id from student_accounts where user_id = auth.uid() and revoked_at is null)
         or e.student_id in (select s.id from students s where s.family_id in (select family_id from guardians where user_id = auth.uid())))
$$;
create policy sessions_student_read on public.class_sessions for select to authenticated using (batch_id in (select app.my_batch_ids()));
create policy attendance_student_read on public.attendance for select to authenticated using (student_id in (select app.my_student_ids()));
create policy announcements_member_read on public.announcements for select to authenticated using (batch_id is null and exists (select 1 from app.my_batch_ids() x limit 1) or batch_id in (select app.my_batch_ids()));
create policy credits_self_read on public.lesson_credits for select to authenticated using (student_id in (select app.my_student_ids()) or student_id in (select id from public.students where family_id in (select app.my_family_ids())));
create policy makeup_self_read on public.makeup_requests for select to authenticated using (student_id in (select app.my_student_ids()) or student_id in (select id from public.students where family_id in (select app.my_family_ids())));

-- Guardians: only their own family's records.
create policy families_guardian_read on public.families for select to authenticated using (id in (select app.my_family_ids()));
create policy guardians_self_read on public.guardians for select to authenticated using (family_id in (select app.my_family_ids()));
create policy students_guardian_read on public.students for select to authenticated using (family_id in (select app.my_family_ids()));
create policy invoices_guardian_read on public.invoices for select to authenticated using (family_id in (select app.my_family_ids()));
create policy lines_guardian_read on public.invoice_lines for select to authenticated using (exists (select 1 from public.invoices i where i.id = invoice_id and i.family_id in (select app.my_family_ids())));
create policy payments_guardian_read on public.payments for select to authenticated using (family_id in (select app.my_family_ids()));
create policy receipts_guardian_read on public.receipts for select to authenticated using (family_id in (select app.my_family_ids()));

-- Private storage bucket for payment proofs and receipts (Supabase only; skipped on plain Postgres).
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('proofs', 'proofs', false, 5242880, array['image/jpeg','image/png','image/webp','application/pdf'])
    on conflict (id) do nothing;
  end if;
end $$;

-- Finance staff may read proofs belonging to their institute (objects are stored as <institute_id>/<payment_id>/<file>).
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    execute $p$create policy proofs_staff_read on storage.objects for select to authenticated using (bucket_id = 'proofs' and app.is_finance(((storage.foldername(name))[1])::uuid))$p$;
  end if;
end $$;

-- ===== 20261014000003_money_engine.sql =====
-- Money engine: numbering, tax, ledger views, allocation, receipts, gateway events.

-- ---------------------------------------------------------------- numbering
create or replace function app.next_number(p_inst uuid, p_kind text, p_prefix text) returns text
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_year int := extract(year from app.today()); v_n int;
begin
  insert into counters (institute_id, kind, year, value) values (p_inst, p_kind, v_year, 1)
  on conflict (institute_id, kind, year) do update set value = counters.value + 1 returning value into v_n;
  return p_prefix || '-' || v_year || '-' || lpad(v_n::text, 4, '0');
end $$;

create or replace function app.peek_number(p_inst uuid, p_kind text, p_prefix text) returns text
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v_year int := extract(year from app.today()); v_n int;
begin
  select coalesce(max(value), 0) + 1 into v_n from counters where institute_id = p_inst and kind = p_kind and year = v_year;
  return p_prefix || '-' || v_year || '-' || lpad(v_n::text, 4, '0');
end $$;

-- ---------------------------------------------------------------- tax (frozen into each invoice at issue)
create or replace function app.compute_tax(p_inst uuid, p_net numeric)
returns table (total numeric, taxable numeric, tax numeric, mode text, rate numeric)
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare i institutes;
begin
  select * into i from institutes where id = p_inst;
  if not i.gst_configured then return query select p_net, p_net, 0::numeric, 'unconfigured'::text, 0::numeric;
  elsif not i.gst_registered then return query select p_net, p_net, 0::numeric, 'not_registered'::text, 0::numeric;
  elsif i.prices_include_gst then
    return query select p_net, round(p_net / (1 + i.gst_rate / 100), 2), p_net - round(p_net / (1 + i.gst_rate / 100), 2), 'inclusive'::text, i.gst_rate;
  else
    return query select p_net + round(p_net * i.gst_rate / 100, 2), p_net, round(p_net * i.gst_rate / 100, 2), 'exclusive'::text, i.gst_rate;
  end if;
end $$;

-- ---------------------------------------------------------------- ledger views (internal; used by SECURITY DEFINER functions)
create or replace view app.v_invoice as
select i.*,
  coalesce((select sum(a.amount) from payment_allocations a join payments p on p.id = a.payment_id where a.invoice_id = i.id and p.state = 'verified'), 0) as paid,
  coalesce((select sum(j.amount) from invoice_adjustments j where j.invoice_id = i.id), 0) as adjusted,
  greatest(i.grand_total
    - coalesce((select sum(a.amount) from payment_allocations a join payments p on p.id = a.payment_id where a.invoice_id = i.id and p.state = 'verified'), 0)
    - coalesce((select sum(j.amount) from invoice_adjustments j where j.invoice_id = i.id), 0), 0) as balance,
  exists (select 1 from payment_invoices pi join payments p on p.id = pi.payment_id
          where pi.invoice_id = i.id and p.state in ('pending_provider','pending_manual_review','needs_clarification','initiated')) as has_pending,
  exists (select 1 from collection_cases c where c.invoice_id = i.id and c.type in ('hold','dispute') and c.state = 'open') as on_hold
from invoices i where i.state = 'issued';

create or replace function app.inv_status(b numeric, paid numeric, due date, pending boolean, hold boolean) returns text language sql stable as $$
  select case when b <= 0 then 'paid' when pending then 'processing' when hold then 'on_hold'
              when due < app.today() then 'overdue' when paid > 0 then 'partial' else 'open' end
$$;

create or replace function app.family_credit(p_family uuid) returns numeric language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(sum(case when p.channel <> 'credit' then p.verified_amount - coalesce((select sum(a.amount) from payment_allocations a where a.payment_id = p.id), 0)
                           else -p.verified_amount end), 0)
  from payments p where p.family_id = p_family and p.state = 'verified'
$$;

-- ---------------------------------------------------------------- audit / outbox
create or replace function app.audit(p_inst uuid, p_entity text, p_id text, p_type text, p_before jsonb default null, p_after jsonb default null) returns void
language sql security definer set search_path = public, app, pg_temp as $$
  insert into audit_events (institute_id, actor, entity, entity_id, event_type, before, after) values (p_inst, auth.uid(), p_entity, p_id, p_type, p_before, p_after)
$$;
create or replace function app.enqueue(p_inst uuid, p_family uuid, p_template text, p_payload jsonb, p_dedupe text default null) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  insert into notification_outbox (institute_id, family_id, template, channel, payload, dedupe_key)
  values (p_inst, p_family, p_template, 'in_app+share', p_payload, p_dedupe) on conflict do nothing;
end $$;

-- ---------------------------------------------------------------- invoice creation (immutable snapshot)
-- p_lines: [{"description":..., "amount":..., "service_period":...}]
create or replace function app.create_invoice(p_inst uuid, p_family uuid, p_student uuid, p_enrollment uuid, p_batch uuid, p_period text,
  p_due date, p_lines jsonb, p_discount numeric, p_source text default 'issued', p_issued date default null, p_import uuid default null, p_number text default null)
returns uuid language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_id uuid := gen_random_uuid(); v_sub numeric; v_net numeric; t record; i institutes; l jsonb; v_num text;
begin
  select * into i from institutes where id = p_inst;
  select coalesce(sum((x ->> 'amount')::numeric), 0) into v_sub from jsonb_array_elements(p_lines) x;
  v_net := v_sub - coalesce(p_discount, 0);
  if v_net < 0 then raise exception 'discount_exceeds_amount' using errcode = 'P0001'; end if;
  select * into t from app.compute_tax(p_inst, v_net);
  v_num := coalesce(p_number, app.next_number(p_inst, 'invoice', 'INV'));
  insert into invoices (id, institute_id, family_id, student_id, enrollment_id, batch_id, invoice_number, period, issued_on, due_on, source,
                        subtotal, discount, tax_total, grand_total, tax_snapshot, import_id, created_by)
  values (v_id, p_inst, p_family, p_student, p_enrollment, p_batch, v_num, p_period, coalesce(p_issued, app.today()), p_due, p_source,
          v_sub, coalesce(p_discount, 0), case when t.mode = 'exclusive' then t.tax else 0 end, t.total,
          jsonb_build_object('business', i.name, 'gstin', i.gstin, 'mode', t.mode, 'rate', t.rate, 'inclusive', i.prices_include_gst, 'taxable', t.taxable, 'tax', t.tax,
                             'cgst', round(t.tax / 2, 2), 'sgst', t.tax - round(t.tax / 2, 2)),
          p_import, auth.uid());
  for l in select * from jsonb_array_elements(p_lines) loop
    insert into invoice_lines (invoice_id, description, service_period, unit_amount, taxable_amount, total, tax_rate)
    values (v_id, l ->> 'description', l ->> 'service_period', (l ->> 'amount')::numeric, (l ->> 'amount')::numeric, (l ->> 'amount')::numeric, t.rate);
  end loop;
  perform app.audit(p_inst, 'invoice', v_id::text, 'invoice.issued', null, jsonb_build_object('number', v_num, 'total', t.total));
  return v_id;
end $$;

-- ---------------------------------------------------------------- receipts
create or replace function app.issue_receipt(p_payment uuid, p_rows jsonb) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare p payments; i institutes; v_id uuid := gen_random_uuid(); v_num text; v_amt numeric; v_lines jsonb; v_students text; fam families;
begin
  select * into p from payments where id = p_payment;
  select * into i from institutes where id = p.institute_id;
  select * into fam from families where id = p.family_id;
  select coalesce(sum((x ->> 'amount')::numeric), 0) into v_amt from jsonb_array_elements(p_rows) x;
  select coalesce(jsonb_agg(jsonb_build_object('invoice_id', v.id, 'invoice_number', v.invoice_number, 'description', (select min(l.description) from invoice_lines l where l.invoice_id = v.id),
           'student', s.name, 'period_label', to_char(v.due_on, 'FMMon YYYY'), 'amount', (x ->> 'amount')::numeric, 'tax_mode', v.tax_snapshot ->> 'mode', 'tax_rate', v.tax_snapshot ->> 'rate')), '[]'),
         string_agg(distinct s.name, ', ')
    into v_lines, v_students
  from jsonb_array_elements(p_rows) x join invoices v on v.id = (x ->> 'invoice_id')::uuid left join students s on s.id = v.student_id;
  v_num := app.next_number(p.institute_id, 'receipt', 'CP');
  insert into receipts (id, institute_id, payment_id, family_id, receipt_number, amount, snapshot)
  values (v_id, p.institute_id, p_payment, p.family_id, v_num, v_amt,
          jsonb_build_object('business', i.name, 'gstin', case when i.gst_registered then i.gstin end, 'family', fam.label, 'students', v_students,
            'method', coalesce(p.method, p.channel), 'channel', p.channel, 'reference', p.reference, 'lines', v_lines, 'paid_on', coalesce(p.paid_on, app.today())));
  perform app.enqueue(p.institute_id, p.family_id, 'receipt', jsonb_build_object('receipt_number', v_num, 'amount', v_amt), 'receipt:' || v_id);
  perform app.audit(p.institute_id, 'receipt', v_id::text, 'receipt.issued', null, jsonb_build_object('number', v_num, 'payment', p_payment));
  return v_id;
end $$;

-- ---------------------------------------------------------------- verify + allocate
create or replace function app.verify_payment(p_payment uuid, p_amount numeric, p_bank_status text default 'confirmed') returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  update payments set state = 'verified', verified_amount = p_amount, verified_at = now(), verified_by = auth.uid(), bank_match_status = p_bank_status,
         paid_on = coalesce(paid_on, app.today())
  where id = p_payment and state in ('pending_manual_review','needs_clarification','pending_provider','initiated');
  if not found then raise exception 'payment_not_verifiable' using errcode = 'P0001'; end if;
  update payment_proofs set review_state = 'approved', reviewed_by = auth.uid(), reviewed_at = now() where payment_id = p_payment and review_state in ('pending','clarification');
end $$;

-- Suggested allocation. Policies: oldest | selected | proportional (open decision in §19; default 'oldest').
create or replace function app.suggest_allocation(p_payment uuid, p_policy text default 'oldest') returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare p payments; v_left numeric; r record; out jsonb := '[]'; v_amt numeric; v_total_bal numeric;
begin
  select * into p from payments where id = p_payment;
  v_left := coalesce(p.verified_amount, 0) - coalesce((select sum(amount) from payment_allocations where payment_id = p_payment), 0);
  select coalesce(sum(balance), 0) into v_total_bal from app.v_invoice where family_id = p.family_id and balance > 0;
  for r in
    select v.id, v.invoice_number, v.due_on, v.balance, s.name as student, (select min(l.description) from invoice_lines l where l.invoice_id = v.id) as descr,
           exists (select 1 from payment_invoices pi where pi.payment_id = p_payment and pi.invoice_id = v.id) as selected
    from app.v_invoice v left join students s on s.id = v.student_id
    where v.family_id = p.family_id and v.balance > 0
    order by case when p_policy = 'selected' and exists (select 1 from payment_invoices pi where pi.payment_id = p_payment and pi.invoice_id = v.id) then 0 else 1 end, v.due_on, v.created_at
  loop
    if p_policy = 'proportional' then v_amt := least(r.balance, floor(v_left * r.balance / nullif(v_total_bal, 0)));
    else v_amt := least(r.balance, v_left); v_left := v_left - v_amt; end if;
    out := out || jsonb_build_object('invoice_id', r.id, 'invoice_number', r.invoice_number, 'student', r.student, 'description', r.descr, 'due_on', r.due_on,
                                      'balance', r.balance, 'amount', coalesce(v_amt, 0));
  end loop;
  return out;
end $$;

create or replace function app.allocate(p_payment uuid, p_rows jsonb) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare p payments; x jsonb; v_rows jsonb := '[]'; v_amt numeric; v_receipt uuid;
begin
  select * into p from payments where id = p_payment for update;
  if p.state <> 'verified' then raise exception 'payment_not_verified' using errcode = 'P0001'; end if;
  for x in select * from jsonb_array_elements(p_rows) loop
    v_amt := (x ->> 'amount')::numeric;
    if v_amt is null or v_amt < 0 then raise exception 'bad_allocation' using errcode = 'P0001'; end if;
    if v_amt = 0 then continue; end if;
    insert into payment_allocations (payment_id, invoice_id, amount, applied_by) values (p_payment, (x ->> 'invoice_id')::uuid, v_amt, auth.uid());
    v_rows := v_rows || jsonb_build_object('invoice_id', x ->> 'invoice_id', 'amount', v_amt);
  end loop;
  if jsonb_array_length(v_rows) = 0 then raise exception 'nothing_to_allocate' using errcode = 'P0001'; end if;
  v_receipt := app.issue_receipt(p_payment, v_rows);
  perform app.audit(p.institute_id, 'payment', p_payment::text, 'payment.allocated', null, v_rows);
  -- paying clears open promise cases for invoices now settled
  update collection_cases c set state = 'kept', resolved_at = now()
   where c.family_id = p.family_id and c.type = 'promise' and c.state = 'open'
     and not exists (select 1 from app.v_invoice v where v.family_id = p.family_id and v.balance > 0 and v.due_on <= app.today());
  return v_receipt;
end $$;

-- ---------------------------------------------------------------- gateway events (idempotent, order-safe)
create or replace function app.apply_gateway_event(p_provider text, p_event_id text, p_order_id text, p_provider_payment_id text, p_status text, p_amount numeric, p_raw jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public, app, pg_temp as $$
declare p payments; v_rows jsonb := '[]'; r record; v_left numeric; v_amt numeric;
begin
  insert into webhook_events (provider, event_id, payload) values (p_provider, p_event_id, p_raw) on conflict do nothing;
  if not found then return jsonb_build_object('result', 'duplicate_ignored'); end if;
  select * into p from payments where provider = p_provider and provider_order_id = p_order_id for update;
  if not found then return jsonb_build_object('result', 'unknown_order'); end if;

  if p_status in ('failed', 'cancelled', 'expired') then
    if p.state in ('verified', 'reversed', 'refunded') then
      perform app.audit(p.institute_id, 'payment', p.id::text, 'gateway.late_failure_ignored', null, jsonb_build_object('event', p_event_id));
      return jsonb_build_object('result', 'ignored_already_final');
    end if;
    update payments set state = p_status, reason = coalesce(p_raw ->> 'reason', p_status) where id = p.id;
    return jsonb_build_object('result', p_status, 'payment_id', p.id);
  end if;

  if p_status <> 'paid' then return jsonb_build_object('result', 'ignored_status'); end if;
  if p.state in ('verified', 'reversed', 'refunded') then return jsonb_build_object('result', 'already_verified', 'payment_id', p.id); end if;
  if p_amount is distinct from p.claimed_amount then
    update payments set state = 'needs_clarification', reference = p_provider_payment_id, reason = 'gateway_amount_mismatch', bank_match_status = 'mismatch' where id = p.id;
    return jsonb_build_object('result', 'amount_mismatch', 'payment_id', p.id);
  end if;

  update payments set state = 'verified', verified_amount = p_amount, verified_at = now(), reference = p_provider_payment_id, bank_match_status = 'confirmed', paid_on = app.today() where id = p.id;
  v_left := p_amount;
  for r in select pi.invoice_id, pi.claimed_amount from payment_invoices pi join app.v_invoice v on v.id = pi.invoice_id where pi.payment_id = p.id and v.balance > 0 order by v.due_on loop
    v_amt := least(v_left, r.claimed_amount, (select balance from app.v_invoice where id = r.invoice_id));
    if v_amt > 0 then
      insert into payment_allocations (payment_id, invoice_id, amount) values (p.id, r.invoice_id, v_amt);
      v_rows := v_rows || jsonb_build_object('invoice_id', r.invoice_id, 'amount', v_amt);
      v_left := v_left - v_amt;
    end if;
  end loop;
  if jsonb_array_length(v_rows) > 0 then perform app.issue_receipt(p.id, v_rows); end if;
  perform app.audit(p.institute_id, 'payment', p.id::text, 'gateway.verified', null, jsonb_build_object('event', p_event_id, 'amount', p_amount));
  return jsonb_build_object('result', 'verified', 'payment_id', p.id);
end $$;

-- ===== 20261014000004_onboarding_import_enrol.sql =====
-- Onboarding, staff, batches, import (S01–S10) and fee links.

alter table public.institutes add column if not exists sibling_discount numeric(12,2) not null default 200;

create or replace function app.require(p_inst uuid, p_roles text[] default array['owner','admin']) returns void
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  if auth.uid() is null or not app.is_role(p_inst, p_roles) then raise exception 'forbidden' using errcode = '42501'; end if;
end $$;

create or replace function app.slot_label(p_slots jsonb) returns text language sql immutable as $$
  select coalesce(
    (select string_agg((array['Sun','Mon','Tue','Wed','Thu','Fri','Sat'])[(s ->> 'dow')::int + 1], ' & ' order by (s ->> 'dow')::int)
            || ' ' || ltrim(to_char(((p_slots -> 0) ->> 'start')::time, 'HH12:MI AM'), '0')
     from jsonb_array_elements(p_slots) s), '')
$$;

-- ---------------------------------------------------------------- context / bootstrap (S01–S03)
create or replace function public.my_context() returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  -- invited staff / guardians claim their rows by verified phone number
  update memberships set user_id = auth.uid(), status = 'active' where user_id is null and status = 'invited' and phone = app.my_phone();
  update guardians set user_id = auth.uid() where user_id is null and phone = app.my_phone();
  return jsonb_build_object(
    'user_id', auth.uid(), 'phone', auth.jwt() ->> 'phone',
    'memberships', coalesce((select jsonb_agg(jsonb_build_object('institute_id', i.id, 'institute_name', i.name, 'role', m.role, 'display_name', m.display_name) order by i.name)
                              from memberships m join institutes i on i.id = m.institute_id where m.user_id = auth.uid() and m.status = 'active'), '[]'),
    'students', coalesce((select jsonb_agg(jsonb_build_object('institute_id', i.id, 'institute_name', i.name, 'student_id', a.student_id, 'display_name', a.display_name,
                           'age_group', st.age_group, 'family_id', st.family_id))
                           from student_accounts a join students st on st.id = a.student_id join institutes i on i.id = a.institute_id where a.user_id = auth.uid() and a.revoked_at is null), '[]'),
    'families', coalesce((select jsonb_agg(distinct jsonb_build_object('institute_id', i.id, 'institute_name', i.name, 'family_id', f.id, 'family_label', f.label, 'guardian_name', g.name))
                           from guardians g join families f on f.id = g.family_id join institutes i on i.id = f.institute_id where g.user_id = auth.uid()), '[]'));
end $$;

create or replace function public.bootstrap_owner(p_full_name text, p_business_name text) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if coalesce(trim(p_business_name), '') = '' or coalesce(trim(p_full_name), '') = '' then raise exception 'name_required' using errcode = 'P0001'; end if;
  select i.id into v_id from institutes i join memberships m on m.institute_id = i.id
   where m.user_id = auth.uid() and m.role = 'owner' and lower(i.name) = lower(trim(p_business_name));
  if v_id is not null then return v_id; end if;
  insert into institutes (name, created_by, phone) values (trim(p_business_name), auth.uid(), app.my_phone()) returning id into v_id;
  insert into memberships (institute_id, user_id, role, display_name, phone) values (v_id, auth.uid(), 'owner', trim(p_full_name), app.my_phone());
  perform app.audit(v_id, 'institute', v_id::text, 'institute.created', null, jsonb_build_object('name', p_business_name));
  return v_id;
end $$;

-- ---------------------------------------------------------------- settings (S04 + GST + payments)
create or replace function public.get_settings(p_inst uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare i institutes;
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  select * into i from institutes where id = p_inst;
  return to_jsonb(i) - 'created_by' - 'logo_path';
end $$;

create or replace function public.save_business_profile(p_inst uuid, p_name text, p_category text, p_city text, p_gst_registered boolean default null) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform app.require(p_inst);
  if coalesce(trim(p_name), '') = '' then raise exception 'name_required' using errcode = 'P0001'; end if;
  update institutes set name = trim(p_name), category = coalesce(p_category, category), city_state = p_city,
         gst_registered = coalesce(p_gst_registered, gst_registered),
         gst_configured = case when p_gst_registered is false then true else gst_configured end   -- "Not registered" is a complete GST answer; "Registered" needs a GSTIN first
   where id = p_inst;
  perform app.audit(p_inst, 'institute', p_inst::text, 'institute.profile_saved');
end $$;

create or replace function public.save_gst_settings(p_inst uuid, p_registered boolean, p_gstin text, p_rate numeric, p_inclusive boolean, p_frequency text, p_threshold numeric) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform app.require(p_inst);
  if p_registered and coalesce(p_gstin, '') !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' then raise exception 'invalid_gstin' using errcode = 'P0001'; end if;
  update institutes set gst_configured = true, gst_registered = p_registered, gstin = case when p_registered then p_gstin end, gst_rate = coalesce(p_rate, 18),
         prices_include_gst = coalesce(p_inclusive, true), filing_frequency = coalesce(p_frequency, 'quarterly'), gst_threshold = coalesce(p_threshold, gst_threshold)
   where id = p_inst;
  perform app.audit(p_inst, 'institute', p_inst::text, 'institute.gst_saved', null, jsonb_build_object('registered', p_registered, 'rate', p_rate, 'inclusive', p_inclusive));
end $$;

create or replace function public.save_payment_settings(p_inst uuid, p_upi_vpa text, p_gateway boolean, p_direct boolean, p_passthrough boolean, p_sibling_discount numeric default null) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform app.require(p_inst);
  update institutes set upi_vpa = p_upi_vpa, gateway_enabled = p_gateway, direct_upi_enabled = p_direct, passthrough_fee = p_passthrough,
         sibling_discount = coalesce(p_sibling_discount, sibling_discount) where id = p_inst;
  perform app.audit(p_inst, 'institute', p_inst::text, 'institute.payment_policy_saved');
end $$;

-- ---------------------------------------------------------------- staff & batches
create or replace function public.invite_staff(p_inst uuid, p_name text, p_phone text, p_role text) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_id uuid;
begin
  perform app.require(p_inst);
  if p_role not in ('admin','teacher','accountant') then raise exception 'invalid_role' using errcode = 'P0001'; end if;
  if app.norm_phone(p_phone) is null or length(app.norm_phone(p_phone)) < 10 then raise exception 'invalid_phone' using errcode = 'P0001'; end if;
  insert into memberships (institute_id, role, display_name, phone, status) values (p_inst, p_role, p_name, app.norm_phone(p_phone), 'invited') returning id into v_id;
  perform app.audit(p_inst, 'membership', v_id::text, 'staff.invited', null, jsonb_build_object('role', p_role));
  return v_id;
end $$;

create or replace function public.list_staff(p_inst uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', display_name, 'role', role, 'status', status, 'phone', phone) order by role, display_name) from memberships where institute_id = p_inst and status <> 'revoked'), '[]');
end $$;

create or replace function public.create_batch(p_inst uuid, p_name text, p_teacher_name text, p_teacher_phone text, p_days int[], p_start time, p_minutes int,
  p_capacity int, p_room text default null, p_fee numeric default null, p_subject text default null, p_level text default null) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_id uuid; v_slots jsonb; v_teacher uuid; v_end time;
begin
  perform app.require(p_inst);
  if coalesce(trim(p_name), '') = '' then raise exception 'name_required' using errcode = 'P0001'; end if;
  if p_days is null or array_length(p_days, 1) is null then raise exception 'days_required' using errcode = 'P0001'; end if;
  v_end := p_start + make_interval(mins => coalesce(p_minutes, 60));
  if v_end <= p_start then raise exception 'invalid_time_range' using errcode = 'P0001'; end if;
  if coalesce(trim(p_teacher_name), '') <> '' then
    select id into v_teacher from memberships where institute_id = p_inst and role = 'teacher' and status <> 'revoked' and lower(display_name) = lower(trim(p_teacher_name)) limit 1;
    if v_teacher is null then
      insert into memberships (institute_id, role, display_name, phone, status) values (p_inst, 'teacher', trim(p_teacher_name), app.norm_phone(p_teacher_phone), 'invited') returning id into v_teacher;
    elsif app.norm_phone(p_teacher_phone) is not null then
      update memberships set phone = app.norm_phone(p_teacher_phone) where id = v_teacher and phone is null;
    end if;
  end if;
  select jsonb_agg(jsonb_build_object('dow', d, 'start', to_char(p_start, 'HH24:MI'), 'end', to_char(v_end, 'HH24:MI')) order by d) into v_slots from unnest(p_days) d;
  insert into batches (institute_id, name, subject, level, room, teacher_membership_id, capacity, weekly_slots, base_fee)
  values (p_inst, trim(p_name), p_subject, p_level, nullif(trim(coalesce(p_room, '')), ''), v_teacher, coalesce(p_capacity, 15), v_slots, coalesce(p_fee, 0)) returning id into v_id;
  perform app.generate_sessions(v_id, app.today(), app.today() + 90);
  perform app.audit(p_inst, 'batch', v_id::text, 'batch.created');
  return v_id;
end $$;

create or replace function public.batch_options(p_inst uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  return coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'capacity', b.capacity, 'filled', (select count(*) from enrollments e where e.batch_id = b.id and e.status = 'active'),
      'slot', app.slot_label(b.weekly_slots), 'fee', b.base_fee, 'teacher', m.display_name) order by b.name)
    from batches b left join memberships m on m.id = b.teacher_membership_id where b.institute_id = p_inst and b.status = 'active'), '[]');
end $$;

-- ---------------------------------------------------------------- import (S05)
create or replace function public.import_preview(p_inst uuid, p_source text, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_id uuid := gen_random_uuid(); r jsonb; n int := 0; v_valid int := 0; v_phone text; v_dups jsonb := '[]'; v_bad jsonb := '[]'; v_seen text[] := '{}'; v_key text; v_exist boolean; v_batch uuid;
begin
  perform app.require(p_inst);
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'empty_import' using errcode = 'P0001'; end if;
  if jsonb_array_length(p_rows) > 2000 then raise exception 'import_too_large' using errcode = 'P0001'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    n := n + 1;
    v_phone := app.norm_phone(r ->> 'phone');
    if coalesce(trim(r ->> 'name'), '') = '' then v_bad := v_bad || jsonb_build_object('row', n, 'error', 'Missing student name'); continue; end if;
    if v_phone is null or length(v_phone) < 10 then v_bad := v_bad || jsonb_build_object('row', n, 'error', 'Invalid guardian phone'); continue; end if;
    if coalesce(trim(r ->> 'guardian_name'), '') = '' then v_bad := v_bad || jsonb_build_object('row', n, 'error', 'Missing guardian name'); continue; end if;
    if coalesce(nullif(r ->> 'opening_balance', ''), '0') !~ '^[0-9]+(\.[0-9]{1,2})?$' then v_bad := v_bad || jsonb_build_object('row', n, 'error', 'Opening balance is not a number'); continue; end if;
    v_key := v_phone || '|' || lower(trim(r ->> 'name'));
    select exists (select 1 from students s join guardians g on g.family_id = s.family_id
                    where s.institute_id = p_inst and g.phone = v_phone and lower(s.name) = lower(trim(r ->> 'name'))) into v_exist;
    if v_key = any (v_seen) or v_exist then
      v_dups := v_dups || jsonb_build_object('row', n, 'name', r ->> 'name', 'phone', v_phone, 'reason', case when v_exist then 'Already enrolled' else 'Duplicate in file' end);
    else v_valid := v_valid + 1; end if;
    v_seen := v_seen || v_key;
  end loop;
  insert into import_batches (id, institute_id, source_name, rows, summary, created_by)
  values (v_id, p_inst, p_source, p_rows, jsonb_build_object('total', n, 'valid', v_valid, 'duplicates', v_dups, 'invalid', v_bad), auth.uid());
  return jsonb_build_object('import_id', v_id, 'total', n, 'valid', v_valid, 'duplicates', v_dups, 'invalid', v_bad);
end $$;

create or replace function public.import_commit(p_import uuid, p_resolution text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare ib import_batches; r jsonb; n int := 0; v_phone text; v_fam uuid; v_stu uuid; v_enr uuid; v_batch batches; v_made int := 0; v_skipped int := 0; v_name text;
        v_exist uuid; v_dup boolean; v_seen text[] := '{}'; v_key text; v_bal numeric; v_fee numeric;
begin
  select * into ib from import_batches where id = p_import for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform app.require(ib.institute_id);
  if ib.state <> 'preview' then raise exception 'import_not_pending' using errcode = 'P0001'; end if;
  if p_resolution not in ('merge','skip','create') then raise exception 'resolution_required' using errcode = 'P0001'; end if;
  for r in select * from jsonb_array_elements(ib.rows) loop
    n := n + 1;
    v_phone := app.norm_phone(r ->> 'phone'); v_name := trim(r ->> 'name');
    continue when coalesce(v_name, '') = '' or v_phone is null or length(v_phone) < 10 or coalesce(trim(r ->> 'guardian_name'), '') = ''
               or coalesce(nullif(r ->> 'opening_balance', ''), '0') !~ '^[0-9]+(\.[0-9]{1,2})?$';
    v_key := v_phone || '|' || lower(v_name);
    select s.id into v_exist from students s join guardians g on g.family_id = s.family_id where s.institute_id = ib.institute_id and g.phone = v_phone and lower(s.name) = lower(v_name) limit 1;
    v_dup := v_exist is not null or v_key = any (v_seen);
    v_seen := v_seen || v_key;
    if v_dup and p_resolution in ('skip','merge') then v_skipped := v_skipped + 1; continue; end if;
    -- family: reuse by guardian phone (siblings share one bill), else create
    select g.family_id into v_fam from guardians g where g.institute_id = ib.institute_id and g.phone = v_phone order by g.created_at limit 1;
    if v_fam is null then
      insert into families (institute_id, label, import_id) values (ib.institute_id, split_part(trim(r ->> 'guardian_name'), ' ', 2) || ' family', p_import) returning id into v_fam;
      update families set label = case when label = ' family' then trim(r ->> 'guardian_name') || ' family' else label end where id = v_fam;
      insert into guardians (institute_id, family_id, name, phone, email, import_id) values (ib.institute_id, v_fam, trim(r ->> 'guardian_name'), v_phone, nullif(r ->> 'email', ''), p_import);
    end if;
    insert into students (institute_id, family_id, name, age_group, import_id) values (ib.institute_id, v_fam, v_name, coalesce(nullif(r ->> 'age_group', ''), 'minor'), p_import) returning id into v_stu;
    v_made := v_made + 1;
    select * into v_batch from batches where institute_id = ib.institute_id and lower(name) = lower(coalesce(r ->> 'batch', '')) and status = 'active';
    if found then
      v_fee := coalesce(nullif(r ->> 'fee', '')::numeric, v_batch.base_fee);
      insert into enrollments (institute_id, student_id, batch_id, start_on, base_fee, import_id) values (ib.institute_id, v_stu, v_batch.id, app.today(), v_fee, p_import) returning id into v_enr;
    else v_enr := null; end if;
    v_bal := coalesce(nullif(r ->> 'opening_balance', '')::numeric, 0);
    if v_bal > 0 then
      perform app.create_invoice(ib.institute_id, v_fam, v_stu, v_enr, v_batch.id, null, coalesce(nullif(r ->> 'due_on', '')::date, app.today()),
        jsonb_build_array(jsonb_build_object('description', 'Opening balance (imported)', 'amount', v_bal)), 0, 'imported', null, p_import);
    end if;
  end loop;
  update import_batches set state = 'committed', committed_at = now(), summary = summary || jsonb_build_object('created', v_made, 'skipped', v_skipped, 'resolution', p_resolution) where id = p_import;
  perform app.audit(ib.institute_id, 'import', p_import::text, 'import.committed', null, jsonb_build_object('created', v_made, 'skipped', v_skipped));
  return jsonb_build_object('created', v_made, 'skipped', v_skipped);
end $$;

create or replace function public.import_revert(p_import uuid) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare ib import_batches;
begin
  select * into ib from import_batches where id = p_import for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform app.require(ib.institute_id);
  if ib.state <> 'committed' then raise exception 'import_not_committed' using errcode = 'P0001'; end if;
  if exists (select 1 from payment_allocations a join invoices i on i.id = a.invoice_id where i.import_id = p_import)
     or exists (select 1 from payment_invoices pi join invoices i on i.id = pi.invoice_id where i.import_id = p_import) then
    raise exception 'import_has_payments' using errcode = 'P0001';
  end if;
  perform set_config('app.allow_invoice_delete', 'on', true);
  delete from invoices where import_id = p_import;
  delete from enrollments where import_id = p_import;
  delete from students where import_id = p_import;
  delete from guardians where import_id = p_import;
  delete from families where import_id = p_import;
  perform set_config('app.allow_invoice_delete', 'off', true);
  update import_batches set state = 'reverted', reverted_at = now() where id = p_import;
  perform app.audit(ib.institute_id, 'import', p_import::text, 'import.reverted');
end $$;

-- ---------------------------------------------------------------- enrolment wizard (S06–S09)
create or replace function public.wizard_context(p_inst uuid, p_guardian_phone text) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v_fam uuid; i institutes;
begin
  perform app.require(p_inst);
  select * into i from institutes where id = p_inst;
  select g.family_id into v_fam from guardians g where g.institute_id = p_inst and g.phone = app.norm_phone(p_guardian_phone) limit 1;
  return jsonb_build_object('family_id', v_fam,
    'family_label', (select label from families where id = v_fam),
    'siblings', coalesce((select jsonb_agg(s.name) from students s where s.family_id = v_fam and s.status <> 'dropped'), '[]'),
    'sibling_discount', case when v_fam is not null and exists (select 1 from students s where s.family_id = v_fam and s.status = 'active') then i.sibling_discount else 0 end);
end $$;

create or replace function public.check_enrolment(p_inst uuid, p_batch uuid, p_family uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare b batches; v_filled int; v_conf jsonb := '[]'; r record;
begin
  perform app.require(p_inst);
  select * into b from batches where id = p_batch and institute_id = p_inst;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  select count(*) into v_filled from enrollments where batch_id = p_batch and status = 'active';
  -- teacher double-booking across batches at the same weekday/time
  for r in select b2.name from batches b2 where b2.institute_id = p_inst and b2.id <> p_batch and b2.status = 'active' and b2.teacher_membership_id is not null
             and b2.teacher_membership_id = b.teacher_membership_id and exists (select 1 from jsonb_array_elements(b2.weekly_slots) s2, jsonb_array_elements(b.weekly_slots) s1
               where s1 ->> 'dow' = s2 ->> 'dow' and (s1 ->> 'start')::time < (s2 ->> 'end')::time and (s2 ->> 'start')::time < (s1 ->> 'end')::time) loop
    v_conf := v_conf || jsonb_build_object('type', 'teacher', 'message', 'Teacher also teaches ' || r.name || ' at this time');
  end loop;
  -- siblings with another class at the same time
  if p_family is not null then
    for r in select b2.name, s.name as student from enrollments e join students s on s.id = e.student_id join batches b2 on b2.id = e.batch_id
             where s.family_id = p_family and e.status = 'active' and b2.id <> p_batch and exists (select 1 from jsonb_array_elements(b2.weekly_slots) s2, jsonb_array_elements(b.weekly_slots) s1
               where s1 ->> 'dow' = s2 ->> 'dow' and (s1 ->> 'start')::time < (s2 ->> 'end')::time and (s2 ->> 'start')::time < (s1 ->> 'end')::time) loop
      v_conf := v_conf || jsonb_build_object('type', 'family', 'message', r.student || ' already has ' || r.name || ' at this time');
    end loop;
  end if;
  return jsonb_build_object('capacity', b.capacity, 'filled', v_filled, 'full', v_filled >= b.capacity, 'slot', app.slot_label(b.weekly_slots), 'fee', b.base_fee, 'conflicts', v_conf);
end $$;

create or replace function app.enrollment_amount(p_batch uuid, p_model text, p_base numeric, p_extra_members int default 0) returns numeric
language sql stable security definer set search_path = public, app, pg_temp as $$
  select case when p_model = 'per_batch_split'
              then round(p_base / greatest((select count(*) from enrollments where batch_id = p_batch and status = 'active') + p_extra_members, 1), 2)
              else p_base end
$$;

create or replace function public.invoice_preview(p_inst uuid, p_batch uuid, p_fee_model text, p_base numeric, p_discount numeric, p_discount_label text) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v_amt numeric; v_net numeric; t record;
begin
  perform app.require(p_inst);
  v_amt := app.enrollment_amount(p_batch, p_fee_model, p_base, 1);
  v_net := v_amt - coalesce(p_discount, 0);
  if v_net < 0 then raise exception 'discount_exceeds_amount' using errcode = 'P0001'; end if;
  select * into t from app.compute_tax(p_inst, v_net);
  return jsonb_build_object('invoice_number', app.peek_number(p_inst, 'invoice', 'INV'), 'tuition', v_amt, 'discount', coalesce(p_discount, 0), 'discount_label', p_discount_label,
                            'net', v_net, 'total', t.total, 'tax', t.tax, 'taxable', t.taxable, 'tax_mode', t.mode, 'tax_rate', t.rate);
end $$;

create or replace function app.period_key(p_freq text, p_date date) returns text language sql immutable as $$
  select case p_freq
    when 'monthly' then to_char(p_date, 'YYYY-MM')
    when 'quarterly' then to_char(p_date, 'YYYY') || '-Q' || extract(quarter from p_date)::int
    when 'term' then to_char(p_date, 'YYYY') || '-T' || ((extract(month from p_date)::int - 1) / 4 + 1)
    else 'once' end
$$;

-- One transaction: family (linked by guardian phone), student, enrolment, first invoice, fee link.
create or replace function public.enrol_student(p_inst uuid, p_student_name text, p_age_group text, p_guardian_name text, p_guardian_phone text, p_batch uuid, p_start_on date,
  p_custom_slot text, p_fee_model text, p_frequency text, p_base_fee numeric, p_discount numeric, p_discount_label text, p_first_due date) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_phone text := app.norm_phone(p_guardian_phone); v_fam uuid; v_stu uuid; v_enr uuid; v_inv uuid; v_check jsonb; v_amt numeric; v_period text; v_token text; v_num text; b batches;
begin
  perform app.require(p_inst);
  if coalesce(trim(p_student_name), '') = '' or coalesce(trim(p_guardian_name), '') = '' or v_phone is null or length(v_phone) < 10 then raise exception 'invalid_student_details' using errcode = 'P0001'; end if;
  if p_fee_model not in ('per_student','per_batch_split','class_pack') or p_frequency not in ('monthly','quarterly','term','one_time') then raise exception 'invalid_fee_model' using errcode = 'P0001'; end if;
  select * into b from batches where id = p_batch and institute_id = p_inst for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  select g.family_id into v_fam from guardians g where g.institute_id = p_inst and g.phone = v_phone order by g.created_at limit 1;
  v_check := public.check_enrolment(p_inst, p_batch, v_fam);
  if (v_check ->> 'full')::boolean then raise exception 'batch_full' using errcode = 'P0001'; end if;
  if v_fam is not null and exists (select 1 from students s join enrollments e on e.student_id = s.id where s.family_id = v_fam and lower(s.name) = lower(trim(p_student_name)) and e.batch_id = p_batch and e.status = 'active') then
    raise exception 'already_enrolled' using errcode = 'P0001';
  end if;
  if v_fam is null then
    insert into families (institute_id, label) values (p_inst, coalesce(nullif(split_part(trim(p_guardian_name), ' ', 2), ''), trim(p_guardian_name)) || ' family') returning id into v_fam;
    insert into guardians (institute_id, family_id, name, phone) values (p_inst, v_fam, trim(p_guardian_name), v_phone);
  end if;
  select id into v_stu from students where family_id = v_fam and lower(name) = lower(trim(p_student_name)) limit 1;
  if v_stu is null then
    insert into students (institute_id, family_id, name, age_group, joined_on) values (p_inst, v_fam, trim(p_student_name), coalesce(p_age_group, 'minor'), p_start_on) returning id into v_stu;
  end if;
  insert into enrollments (institute_id, student_id, batch_id, start_on, custom_slot, fee_model, frequency, base_fee, discount_label, discount_amount, billing_day)
  values (p_inst, v_stu, p_batch, p_start_on, nullif(trim(coalesce(p_custom_slot, '')), ''), p_fee_model, p_frequency, p_base_fee, p_discount_label, coalesce(p_discount, 0), least(extract(day from p_first_due)::int, 28)) returning id into v_enr;
  v_amt := app.enrollment_amount(p_batch, p_fee_model, p_base_fee, 0);
  v_period := app.period_key(p_frequency, p_first_due);
  v_inv := app.create_invoice(p_inst, v_fam, v_stu, v_enr, p_batch, v_period, p_first_due,
    jsonb_build_array(jsonb_build_object('description', case when p_fee_model = 'class_pack' then 'Class pack – ' else 'Tuition – ' end || b.name, 'service_period', v_period, 'amount', v_amt)), coalesce(p_discount, 0));
  update enrollments set last_billed_period = v_period where id = v_enr;
  select invoice_number into v_num from invoices where id = v_inv;
  v_token := public.issue_fee_link(p_inst, v_fam);
  perform app.audit(p_inst, 'student', v_stu::text, 'student.enrolled', null, jsonb_build_object('batch', p_batch, 'invoice', v_num));
  return jsonb_build_object('student_id', v_stu, 'family_id', v_fam, 'enrollment_id', v_enr, 'invoice_id', v_inv, 'invoice_number', v_num, 'token', v_token);
end $$;

-- ---------------------------------------------------------------- fee links (no-install parent access)
create or replace function public.issue_fee_link(p_inst uuid, p_family uuid) returns text
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_token text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  perform app.require(p_inst);
  if not exists (select 1 from families where id = p_family and institute_id = p_inst) then raise exception 'not_found' using errcode = 'P0001'; end if;
  update fee_links set revoked_at = now() where family_id = p_family and revoked_at is null;   -- one live link per family; issuing rotates
  insert into fee_links (institute_id, family_id, token_hash, expires_at, created_by)
  values (p_inst, p_family, encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), now() + interval '30 days', auth.uid());
  perform app.audit(p_inst, 'family', p_family::text, 'fee_link.issued');
  return v_token;
end $$;

create or replace function public.revoke_fee_link(p_inst uuid, p_family uuid) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform app.require(p_inst);
  update fee_links set revoked_at = now() where family_id = p_family and institute_id = p_inst and revoked_at is null;
  perform app.audit(p_inst, 'family', p_family::text, 'fee_link.revoked');
end $$;

create or replace function public.send_invitation(p_inst uuid, p_family uuid, p_token text) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform app.require(p_inst);
  if not exists (select 1 from fee_links where family_id = p_family and token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex') and revoked_at is null and expires_at > now()) then
    raise exception 'invalid_link' using errcode = 'P0001';
  end if;
  perform app.enqueue(p_inst, p_family, 'invitation', jsonb_build_object('guardian', (select name from guardians where family_id = p_family order by created_at limit 1), 'link', '/pay/' || p_token), 'invite:' || p_family || ':' || left(p_token, 6));
  perform app.audit(p_inst, 'family', p_family::text, 'invitation.queued');
end $$;

create or replace function app.family_from_token(p_token text) returns table (family_id uuid, institute_id uuid)
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare l fee_links;
begin
  select * into l from fee_links where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex');
  if not found or l.revoked_at is not null or l.expires_at < now() then raise exception 'invalid_link' using errcode = 'P0001'; end if;
  update fee_links set last_used_at = now() where id = l.id;
  return query select l.family_id, l.institute_id;
end $$;

-- Resolve the acting family for parent endpoints: secure link OR a signed-in guardian.
create or replace function app.resolve_family(p_token text, p_family uuid default null) returns table (family_id uuid, institute_id uuid)
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_f uuid; v_i uuid;
begin
  if p_token is not null then
    return query select * from app.family_from_token(p_token); return;
  end if;
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select f.id, f.institute_id into v_f, v_i from families f where f.id in (select app.my_family_ids()) and (p_family is null or f.id = p_family) order by f.created_at limit 1;
  if v_f is null then raise exception 'forbidden' using errcode = '42501'; end if;
  return query select v_f, v_i;
end $$;

-- ===== 20261014000005_teaching_calendar_students.sql =====
-- Sessions, role-scoped calendars (§27), attendance, lesson credits, student portal (§26).

alter table public.students add column if not exists left_on date;
alter table public.collection_cases add column if not exists pause_reminders boolean not null default true;
alter table public.collection_cases add column if not exists source text not null default 'staff';

-- ---------------------------------------------------------------- sessions
create or replace function app.generate_sessions(p_batch uuid, p_from date, p_to date) returns int
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare b batches; d date; s jsonb; n int := 0;
begin
  select * into b from batches where id = p_batch;
  if not found or b.status <> 'active' then return 0; end if;
  for d in select g::date from generate_series(greatest(p_from, b.start_on), least(p_to, coalesce(b.end_on, p_to)), interval '1 day') g loop
    for s in select * from jsonb_array_elements(b.weekly_slots) loop
      if extract(dow from d)::int = (s ->> 'dow')::int then
        insert into class_sessions (institute_id, batch_id, teacher_membership_id, starts_at, ends_at, room)
        values (b.institute_id, b.id, b.teacher_membership_id, (d + (s ->> 'start')::time) at time zone 'Asia/Kolkata', (d + (s ->> 'end')::time) at time zone 'Asia/Kolkata', b.room)
        on conflict (batch_id, starts_at) do nothing;
        if found then n := n + 1; end if;
      end if;
    end loop;
  end loop;
  return n;
end $$;

-- Cron: keep a rolling 90-day window of generated sessions and expire stale credits.
create or replace function app.extend_sessions() returns int language plpgsql security definer set search_path = public, app, pg_temp as $$
declare r record; n int := 0;
begin
  for r in select id from batches where status = 'active' loop n := n + app.generate_sessions(r.id, app.today(), app.today() + 90); end loop;
  update lesson_credits set state = 'expired' where state = 'open' and expires_on < app.today();
  return n;
end $$;

create or replace function app.can_teach(p_session uuid) returns boolean language sql stable security definer set search_path = public, app, pg_temp as $$
  select exists (select 1 from class_sessions s where s.id = p_session and (
    app.is_role(s.institute_id, array['owner','admin'])
    or s.teacher_membership_id in (select id from memberships where user_id = auth.uid() and role = 'teacher' and status = 'active')))
$$;

-- ---------------------------------------------------------------- calendar (Day / Week / Month are client views over a bounded range)
create or replace function public.calendar_range(p_inst uuid, p_as text, p_from date, p_to date, p_filter text default null) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v_sessions jsonb; v_filters jsonb := '[]'; v_teacher_ids uuid[]; v_students uuid[];
begin
  if p_to - p_from > 62 then raise exception 'range_too_large' using errcode = 'P0001'; end if;   -- bounded interval queries
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_as = 'admin' then
    perform app.require(p_inst, array['owner','admin','accountant']);
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name), '[]') into v_filters from batches where institute_id = p_inst and status = 'active';
  elsif p_as = 'teacher' then
    select array_agg(id) into v_teacher_ids from memberships where institute_id = p_inst and user_id = auth.uid() and role = 'teacher' and status = 'active';
    if v_teacher_ids is null then raise exception 'forbidden' using errcode = '42501'; end if;
  elsif p_as = 'parent' then
    select array_agg(st.id) into v_students from students st where st.institute_id = p_inst and st.family_id in (select app.my_family_ids());
    if v_students is null then raise exception 'forbidden' using errcode = '42501'; end if;
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', split_part(name, ' ', 1)) order by name), '[]') into v_filters from students where id = any (v_students);
  elsif p_as = 'student' then
    select array_agg(student_id) into v_students from student_accounts where institute_id = p_inst and user_id = auth.uid() and revoked_at is null;
    if v_students is null then raise exception 'forbidden' using errcode = '42501'; end if;
  else raise exception 'invalid_role' using errcode = 'P0001'; end if;

  select coalesce(jsonb_agg(x order by x ->> 'date', x ->> 'start'), '[]') into v_sessions from (
    select jsonb_build_object(
      'id', s.id, 'date', to_char(s.starts_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD'),
      'start', to_char(s.starts_at at time zone 'Asia/Kolkata', 'HH24:MI'), 'end', to_char(s.ends_at at time zone 'Asia/Kolkata', 'HH24:MI'),
      'name', b.name, 'batch_id', b.id, 'teacher', coalesce(t.display_name, ''), 'room', coalesce(s.room, b.room, ''),
      'state', case s.status when 'scheduled' then 'Scheduled' when 'cancelled' then 'Cancelled' when 'rescheduled' then 'Rescheduled' else 'Completed' end,
      'enrolled', (select count(*) from enrollments e join students st on st.id = e.student_id where e.batch_id = b.id and e.status = 'active' and st.status in ('active','trial')
                     and e.start_on <= (s.starts_at at time zone 'Asia/Kolkata')::date),
      'students', case when p_as in ('parent','student') then
          (select coalesce(jsonb_agg(split_part(st.name, ' ', 1) order by st.name), '[]') from enrollments e join students st on st.id = e.student_id
            where e.batch_id = b.id and e.status = 'active' and st.id = any (v_students) and (p_as <> 'parent' or p_filter is null or p_filter = 'all' or st.id::text = p_filter)) else '[]'::jsonb end
    ) as x
    from class_sessions s join batches b on b.id = s.batch_id left join memberships t on t.id = coalesce(s.teacher_membership_id, b.teacher_membership_id)
    where s.institute_id = p_inst and (s.starts_at at time zone 'Asia/Kolkata')::date between p_from and p_to
      and (p_as <> 'admin' or p_filter is null or p_filter = 'all' or b.id::text = p_filter)
      and (p_as <> 'teacher' or coalesce(s.teacher_membership_id, b.teacher_membership_id) = any (v_teacher_ids))
      and (p_as not in ('parent','student') or exists (select 1 from enrollments e join students st on st.id = e.student_id
             where e.batch_id = b.id and e.status = 'active' and st.id = any (v_students) and e.start_on <= (s.starts_at at time zone 'Asia/Kolkata')::date
               and (p_as <> 'parent' or p_filter is null or p_filter = 'all' or st.id::text = p_filter)))
  ) q;
  return jsonb_build_object('sessions', v_sessions, 'filters', v_filters);
end $$;

-- ---------------------------------------------------------------- batches (owner screens)
create or replace function public.list_batches(p_inst uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  return jsonb_build_object(
    'enrolled', (select count(*) from students where institute_id = p_inst and status in ('active','trial')),
    'batches', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'slot', app.slot_label(b.weekly_slots), 'capacity', b.capacity,
        'filled', (select count(*) from enrollments e where e.batch_id = b.id and e.status = 'active'), 'room', b.room, 'teacher', t.display_name) order by b.name)
      from batches b left join memberships t on t.id = b.teacher_membership_id where b.institute_id = p_inst and b.status = 'active'), '[]'));
end $$;

create or replace function public.batch_detail(p_batch uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare b batches;
begin
  select * into b from batches where id = p_batch;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform app.require(b.institute_id, array['owner','admin','accountant']);
  return jsonb_build_object('id', b.id, 'name', b.name, 'slot', app.slot_label(b.weekly_slots), 'room', b.room, 'capacity', b.capacity,
    'teacher', (select display_name from memberships where id = b.teacher_membership_id),
    'students', (select count(*) from enrollments where batch_id = b.id and status = 'active'),
    'overdue', (select count(distinct e.student_id) from enrollments e join app.v_invoice v on v.student_id = e.student_id where e.batch_id = b.id and e.status = 'active' and v.balance > 0 and v.due_on < app.today()),
    'roster', coalesce((select jsonb_agg(jsonb_build_object('student_id', s.id, 'name', s.name, 'fee', e.base_fee, 'frequency', e.frequency,
        'status', coalesce((select app.inv_status(v.balance, v.paid, v.due_on, v.has_pending, v.on_hold) from app.v_invoice v where v.student_id = s.id and v.balance > 0 order by v.due_on limit 1), 'paid'))
        order by s.name)
      from enrollments e join students s on s.id = e.student_id where e.batch_id = b.id and e.status = 'active'), '[]'));
end $$;

-- ---------------------------------------------------------------- attendance (teacher / admin)
create or replace function public.attendance_target(p_inst uuid, p_session uuid default null, p_batch uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v_id uuid := p_session; r record;
begin
  if v_id is null then
    select s.id into v_id from class_sessions s join batches b on b.id = s.batch_id
     where s.institute_id = p_inst and s.status in ('scheduled','done') and (p_batch is null or s.batch_id = p_batch) and app.can_teach(s.id)
       and (s.starts_at at time zone 'Asia/Kolkata')::date >= app.today() - case when p_batch is null then 0 else 7 end
     order by ((s.starts_at at time zone 'Asia/Kolkata')::date <> app.today()), abs(extract(epoch from (s.starts_at - now()))) limit 1;
  end if;
  if v_id is null or not app.can_teach(v_id) then return null; end if;
  select s.id, b.name, s.starts_at, s.status, coalesce(s.room, b.room) as room into r from class_sessions s join batches b on b.id = s.batch_id where s.id = v_id;
  return jsonb_build_object('session_id', r.id, 'name', r.name, 'date', to_char(r.starts_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD'), 'start', to_char(r.starts_at at time zone 'Asia/Kolkata', 'HH24:MI'), 'room', r.room, 'status', r.status,
    'students', coalesce((select jsonb_agg(jsonb_build_object('student_id', st.id, 'name', st.name, 'present', (select (a.status in ('present','late')) from attendance a where a.session_id = r.id and a.student_id = st.id)) order by st.name)
      from enrollments e join students st on st.id = e.student_id where e.batch_id = (select batch_id from class_sessions where id = r.id) and e.status = 'active' and st.status in ('active','trial')), '[]'));
end $$;

create or replace function public.attendance_save(p_session uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare s class_sessions; x jsonb; v_new text; v_old text; n int := 0;
begin
  select * into s from class_sessions where id = p_session for update;
  if not found or not app.can_teach(p_session) then raise exception 'forbidden' using errcode = '42501'; end if;
  if s.status = 'cancelled' then raise exception 'session_cancelled' using errcode = 'P0001'; end if;
  for x in select * from jsonb_array_elements(p_rows) loop
    if not exists (select 1 from enrollments e where e.batch_id = s.batch_id and e.student_id = (x ->> 'student_id')::uuid and e.status = 'active') then
      raise exception 'student_not_enrolled' using errcode = 'P0001';
    end if;
    v_new := case when (x ->> 'present')::boolean then 'present' else 'absent' end;
    select status into v_old from attendance where session_id = p_session and student_id = (x ->> 'student_id')::uuid;
    if v_old is distinct from v_new then
      insert into attendance_history (session_id, student_id, old_status, new_status, changed_by) values (p_session, (x ->> 'student_id')::uuid, v_old, v_new, auth.uid());
      insert into attendance (session_id, student_id, status, marked_by) values (p_session, (x ->> 'student_id')::uuid, v_new, auth.uid())
      on conflict (session_id, student_id) do update set status = excluded.status, marked_by = excluded.marked_by, marked_at = now();
      n := n + 1;
    end if;
  end loop;
  update class_sessions set status = 'done', updated_at = now() where id = p_session and status = 'scheduled';
  perform app.audit(s.institute_id, 'session', p_session::text, 'attendance.saved', null, jsonb_build_object('changed', n));
  return jsonb_build_object('changed', n);
end $$;

-- ---------------------------------------------------------------- lesson credits & make-up requests
create or replace function public.teachable_students(p_inst uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not (app.is_role(p_inst, array['owner','admin']) or app.is_role(p_inst, array['teacher'])) then raise exception 'forbidden' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(distinct jsonb_build_object('id', st.id, 'name', st.name))
    from students st join enrollments e on e.student_id = st.id and e.status = 'active' join batches b on b.id = e.batch_id
    where st.institute_id = p_inst and st.status in ('active','trial')
      and (app.is_role(p_inst, array['owner','admin']) or b.teacher_membership_id in (select id from memberships where user_id = auth.uid() and role = 'teacher' and status = 'active'))), '[]');
end $$;

create or replace function public.issue_lesson_credit(p_student uuid, p_reason text, p_expires date) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare st students; v_id uuid; v_ok boolean;
begin
  select * into st from students where id = p_student;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  select app.is_role(st.institute_id, array['owner','admin']) or exists (
    select 1 from enrollments e join batches b on b.id = e.batch_id where e.student_id = p_student and e.status = 'active'
      and b.teacher_membership_id in (select id from memberships where user_id = auth.uid() and role = 'teacher' and status = 'active')) into v_ok;
  if not v_ok then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_reason not in ('Teacher cancelled','Approved absence','Holiday adjustment') then raise exception 'invalid_reason' using errcode = 'P0001'; end if;
  if p_expires is null or p_expires <= app.today() then raise exception 'expiry_must_be_future' using errcode = 'P0001'; end if;
  insert into lesson_credits (institute_id, student_id, enrollment_id, reason, expires_on, issued_by)
  values (st.institute_id, p_student, (select id from enrollments where student_id = p_student and status = 'active' order by start_on limit 1), p_reason, p_expires, auth.uid()) returning id into v_id;
  perform app.enqueue(st.institute_id, st.family_id, 'makeup_credit', jsonb_build_object('student', st.name, 'expires_on', p_expires), 'credit:' || v_id);
  perform app.audit(st.institute_id, 'student', p_student::text, 'credit.issued', null, jsonb_build_object('reason', p_reason, 'expires', p_expires));
  return v_id;
end $$;

-- ---------------------------------------------------------------- student portal (§26)
create or replace function app.student_access(p_student uuid, p_allow_guardian boolean default true) returns students
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare st students;
begin
  select * into st from students where id = p_student;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_student in (select app.my_student_ids()) then return st; end if;
  if p_allow_guardian and st.family_id in (select app.my_family_ids()) then return st; end if;
  if app.is_role(st.institute_id, array['owner','admin']) then return st; end if;
  raise exception 'forbidden' using errcode = '42501';
end $$;

create or replace function public.issue_student_invite(p_student uuid) returns text
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare st students; v_code text;
begin
  select * into st from students where id = p_student;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform app.require(st.institute_id);
  if exists (select 1 from student_accounts where student_id = p_student and revoked_at is null) then raise exception 'already_activated' using errcode = 'P0001'; end if;
  update student_invites set revoked_at = now() where student_id = p_student and used_at is null and revoked_at is null;
  v_code := 'CP-STU-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  insert into student_invites (institute_id, student_id, code_hash, expires_at, issued_by)
  values (st.institute_id, p_student, encode(sha256(convert_to(v_code, 'UTF8')), 'hex'), now() + interval '7 days', auth.uid());
  perform app.audit(st.institute_id, 'student', p_student::text, 'student_invite.issued');
  return v_code;
end $$;

create or replace function public.activate_student(p_code text, p_display_name text, p_account_type text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare inv student_invites; st students;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if coalesce(trim(p_display_name), '') = '' then raise exception 'name_required' using errcode = 'P0001'; end if;
  select * into inv from student_invites where code_hash = encode(sha256(convert_to(upper(trim(coalesce(p_code, ''))), 'UTF8')), 'hex') for update;
  if not found or inv.used_at is not null or inv.revoked_at is not null or inv.expires_at < now() then raise exception 'invalid_invite' using errcode = 'P0001'; end if;
  select * into st from students where id = inv.student_id;
  if (p_account_type = 'adult') <> (st.age_group = 'adult') then raise exception 'account_type_mismatch' using errcode = 'P0001'; end if;
  insert into student_accounts (institute_id, student_id, user_id, display_name) values (inv.institute_id, inv.student_id, auth.uid(), trim(p_display_name));
  update student_invites set used_at = now() where id = inv.id;
  perform app.audit(inv.institute_id, 'student', inv.student_id::text, 'student.activated');
  return jsonb_build_object('student_id', st.id, 'institute_id', inv.institute_id);
end $$;

create or replace function public.student_home(p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare st students; a student_accounts; v_next jsonb; v_att record; v_fees jsonb := null; v_guardian text;
begin
  st := app.student_access(p_student);
  select * into a from student_accounts where student_id = p_student and revoked_at is null;
  select jsonb_build_object('id', s.id, 'date', to_char(s.starts_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD'), 'start', to_char(s.starts_at at time zone 'Asia/Kolkata', 'HH24:MI'),
         'end', to_char(s.ends_at at time zone 'Asia/Kolkata', 'HH24:MI'), 'name', b.name, 'room', coalesce(s.room, b.room), 'teacher', t.display_name, 'state', initcap(s.status), 'batch_id', b.id)
    into v_next
  from class_sessions s join batches b on b.id = s.batch_id left join memberships t on t.id = coalesce(s.teacher_membership_id, b.teacher_membership_id)
  join enrollments e on e.batch_id = b.id and e.student_id = p_student and e.status = 'active'
  where s.starts_at >= now() and s.status in ('scheduled','rescheduled') order by s.starts_at limit 1;
  select count(*) filter (where at.status in ('present','late')) as attended, count(*) as total into v_att
    from attendance at join class_sessions s on s.id = at.session_id
   where at.student_id = p_student and date_trunc('month', s.starts_at at time zone 'Asia/Kolkata') = date_trunc('month', app.today()::timestamp);
  select name into v_guardian from guardians where family_id = st.family_id order by is_billing_contact desc, created_at limit 1;
  if st.age_group = 'adult' and p_student in (select app.my_student_ids()) then
    select jsonb_build_object('amount_due', coalesce(sum(balance), 0), 'overdue', coalesce(bool_or(due_on < app.today()), false)) into v_fees from app.v_invoice where student_id = p_student and balance > 0;
  end if;
  return jsonb_build_object('student_id', st.id, 'name', st.name, 'display_name', coalesce(a.display_name, st.name), 'age_group', st.age_group,
    'academy', (select name from institutes where id = st.institute_id), 'guardian_name', v_guardian, 'next_class', v_next,
    'attendance', jsonb_build_object('attended', v_att.attended, 'total', v_att.total),
    'courses', (select count(*) from enrollments where student_id = p_student and status = 'active'),
    'makeup_credits', (select count(*) from lesson_credits where student_id = p_student and state = 'open' and expires_on >= app.today()),
    'announcements', coalesce((select jsonb_agg(jsonb_build_object('title', n.title, 'body', n.body) order by n.published_at desc)
        from (select an.* from announcements an where an.institute_id = st.institute_id and (an.batch_id is null or an.batch_id in (select batch_id from enrollments where student_id = p_student and status = 'active'))
              order by an.published_at desc limit 2) n), '[]'),
    'fees', v_fees, 'class_reminders', coalesce(a.class_reminders, true));
end $$;

create or replace function public.student_class(p_student uuid, p_batch uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare st students; b batches; v_next jsonb; v_att record;
begin
  st := app.student_access(p_student);
  select b2.* into b from batches b2 join enrollments e on e.batch_id = b2.id and e.student_id = p_student and e.status = 'active' where (p_batch is null or b2.id = p_batch) order by b2.name limit 1;
  if not found then return null; end if;
  select jsonb_build_object('id', s.id, 'date', to_char(s.starts_at at time zone 'Asia/Kolkata', 'YYYY-MM-DD'), 'start', to_char(s.starts_at at time zone 'Asia/Kolkata', 'HH24:MI'), 'end', to_char(s.ends_at at time zone 'Asia/Kolkata', 'HH24:MI'),
         'room', coalesce(s.room, b.room), 'state', initcap(s.status), 'teacher', (select display_name from memberships where id = coalesce(s.teacher_membership_id, b.teacher_membership_id)))
    into v_next from class_sessions s where s.batch_id = b.id and s.starts_at >= now() and s.status in ('scheduled','rescheduled') order by s.starts_at limit 1;
  select count(*) filter (where at.status in ('present','late')) as attended, count(*) as total into v_att
    from attendance at join class_sessions s on s.id = at.session_id where at.student_id = p_student and s.batch_id = b.id;
  return jsonb_build_object('batch_id', b.id, 'name', b.name, 'level', b.level, 'subject', b.subject, 'academy', (select name from institutes where id = st.institute_id),
    'next', v_next, 'attended', v_att.attended, 'total', v_att.total,
    'makeup_requested', exists (select 1 from makeup_requests where student_id = p_student and status = 'requested'));
end $$;

create or replace function public.student_attendance(p_student uuid, p_batch uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare st students; b batches;
begin
  st := app.student_access(p_student);
  select b2.* into b from batches b2 join enrollments e on e.batch_id = b2.id and e.student_id = p_student and e.status = 'active' where (p_batch is null or b2.id = p_batch) order by b2.name limit 1;
  if not found then return null; end if;
  return jsonb_build_object('batch', b.name, 'month', to_char(app.today(), 'FMMonth YYYY'),
    'attended', (select count(*) from attendance a join class_sessions s on s.id = a.session_id where a.student_id = p_student and s.batch_id = b.id and a.status in ('present','late')
                   and date_trunc('month', s.starts_at at time zone 'Asia/Kolkata') = date_trunc('month', app.today()::timestamp)),
    'total', (select count(*) from attendance a join class_sessions s on s.id = a.session_id where a.student_id = p_student and s.batch_id = b.id
                   and date_trunc('month', s.starts_at at time zone 'Asia/Kolkata') = date_trunc('month', app.today()::timestamp)),
    'history', coalesce((select jsonb_agg(jsonb_build_object('label', to_char(s.starts_at at time zone 'Asia/Kolkata', 'Dy FMDD Mon'), 'status', initcap(a.status)) order by s.starts_at desc)
       from (select a2.* from attendance a2 join class_sessions s2 on s2.id = a2.session_id where a2.student_id = p_student and s2.batch_id = b.id order by s2.starts_at desc limit 8) a join class_sessions s on s.id = a.session_id), '[]'));
end $$;

create or replace function public.request_makeup(p_student uuid, p_session uuid default null, p_reason text default null) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare st students; v_id uuid;
begin
  st := app.student_access(p_student);
  if not (p_student in (select app.my_student_ids()) or st.family_id in (select app.my_family_ids())) then raise exception 'forbidden' using errcode = '42501'; end if;
  if exists (select 1 from makeup_requests where student_id = p_student and status = 'requested' and session_id is not distinct from p_session) then raise exception 'request_already_open' using errcode = 'P0001'; end if;
  insert into makeup_requests (institute_id, student_id, session_id, reason, requested_by, enrollment_id)
  values (st.institute_id, p_student, p_session, p_reason, auth.uid(), (select id from enrollments where student_id = p_student and status = 'active' order by start_on limit 1)) returning id into v_id;
  perform app.audit(st.institute_id, 'makeup_request', v_id::text, 'makeup.requested');
  return v_id;      -- review decides; no attendance/credit is changed here
end $$;

create or replace function public.review_makeup(p_request uuid, p_approve boolean, p_expires date default null) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare r makeup_requests;
begin
  select * into r from makeup_requests where id = p_request for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform app.require(r.institute_id);
  if r.status <> 'requested' then raise exception 'already_reviewed' using errcode = 'P0001'; end if;
  update makeup_requests set status = case when p_approve then 'approved' else 'declined' end, reviewed_by = auth.uid(), reviewed_at = now() where id = p_request;
  if p_approve then perform public.issue_lesson_credit(r.student_id, 'Approved absence', coalesce(p_expires, app.today() + 60)); end if;
end $$;

create or replace function public.update_student_preferences(p_student uuid, p_class_reminders boolean) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if p_student not in (select app.my_student_ids()) then raise exception 'forbidden' using errcode = '42501'; end if;
  update student_accounts set class_reminders = p_class_reminders where student_id = p_student and user_id = auth.uid() and revoked_at is null;
end $$;

create or replace function public.create_announcement(p_inst uuid, p_batch uuid, p_title text, p_body text) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_id uuid;
begin
  perform app.require(p_inst);
  insert into announcements (institute_id, batch_id, title, body, created_by) values (p_inst, p_batch, p_title, p_body, auth.uid()) returning id into v_id;
  return v_id;
end $$;

-- Shown on the activation screen once a code is typed (authenticated users only; returns nothing for bad codes).
create or replace function public.invite_preview(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare inv student_invites; st students;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into inv from student_invites where code_hash = encode(sha256(convert_to(upper(trim(coalesce(p_code, ''))), 'UTF8')), 'hex') and used_at is null and revoked_at is null and expires_at > now();
  if not found then return null; end if;
  select * into st from students where id = inv.student_id;
  return jsonb_build_object('academy', (select name from institutes where id = inv.institute_id), 'student', split_part(st.name, ' ', 1), 'age_group', st.age_group,
    'batch', (select b.name from enrollments e join batches b on b.id = e.batch_id where e.student_id = st.id and e.status = 'active' order by e.start_on limit 1));
end $$;

-- ===== 20261014000006_collections_and_parent_payments.sql =====
-- Owner collections (inbox, verify, allocate, offline payments, promises) and parent / student payment access.

-- ---------------------------------------------------------------- actor resolution (secure link | guardian | adult student)
create or replace function app.actor_scope(p_token text, p_user uuid, p_family uuid default null, p_student uuid default null)
returns table (family_id uuid, institute_id uuid, student_id uuid)
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_f uuid; v_i uuid; st students;
begin
  if p_token is not null then
    return query select t.family_id, t.institute_id, null::uuid from app.family_from_token(p_token) t; return;
  end if;
  if p_user is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_student is not null then
    select * into st from students where id = p_student;
    if not found or not exists (select 1 from student_accounts a where a.student_id = p_student and a.user_id = p_user and a.revoked_at is null) then raise exception 'forbidden' using errcode = '42501'; end if;
    if st.age_group <> 'adult' then raise exception 'guardian_managed_billing' using errcode = 'P0001'; end if;   -- minors never inherit billing permissions
    return query select st.family_id, st.institute_id, st.id; return;
  end if;
  select f.id, f.institute_id into v_f, v_i from families f where f.id in (select g.family_id from guardians g where g.user_id = p_user) and (p_family is null or f.id = p_family) order by f.created_at limit 1;
  if v_f is null then raise exception 'forbidden' using errcode = '42501'; end if;
  return query select v_f, v_i, null::uuid;
end $$;

create or replace function app.next_attempt(p_inst uuid) returns text language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v int;
begin
  insert into counters (institute_id, kind, year, value) values (p_inst, 'attempt', 0, 42017)
  on conflict (institute_id, kind, year) do update set value = counters.value + 1 returning value into v;
  return 'PAY-' || v;
end $$;

-- Receipt numbers follow the product copy: CP-2026-0144.
create or replace function app.next_number(p_inst uuid, p_kind text, p_prefix text) returns text
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_year int := extract(year from app.today()); v_n int;
begin
  insert into counters (institute_id, kind, year, value) values (p_inst, p_kind, v_year, 1)
  on conflict (institute_id, kind, year) do update set value = counters.value + 1 returning value into v_n;
  return p_prefix || '-' || v_year || '-' || lpad(v_n::text, 4, '0');
end $$;
create or replace function app.receipt_prefix() returns text language sql immutable as $$ select 'CP' $$;

-- ---------------------------------------------------------------- shared read helpers
create or replace function app.invoice_json(p_row app.v_invoice) returns jsonb language sql stable as $$
  select jsonb_build_object('id', p_row.id, 'number', p_row.invoice_number, 'student_id', p_row.student_id,
    'student', (select name from students where id = p_row.student_id), 'description', (select min(l.description) from invoice_lines l where l.invoice_id = p_row.id),
    'period', p_row.period, 'due_on', p_row.due_on, 'total', p_row.grand_total, 'balance', p_row.balance,
    'status', app.inv_status(p_row.balance, p_row.paid, p_row.due_on, p_row.has_pending, p_row.on_hold), 'days_overdue', greatest(app.today() - p_row.due_on, 0),
    'selectable', p_row.balance > 0 and not p_row.has_pending)
$$;

-- ---------------------------------------------------------------- parent / student reads
create or replace function public.family_bill(p_token text default null, p_family uuid default null, p_student uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare sc record; i institutes; v_invs jsonb; v_total numeric;
begin
  select * into sc from app.actor_scope(p_token, auth.uid(), p_family, p_student);
  select * into i from institutes where id = sc.institute_id;
  select coalesce(jsonb_agg(app.invoice_json(v) order by v.due_on, v.created_at), '[]'), coalesce(sum(v.balance) filter (where not v.has_pending), 0)
    into v_invs, v_total from app.v_invoice v where v.family_id = sc.family_id and v.balance > 0 and (sc.student_id is null or v.student_id = sc.student_id);
  return jsonb_build_object('institute_id', i.id, 'academy', i.name, 'family_id', sc.family_id, 'family', (select label from families where id = sc.family_id),
    'guardian', (select name from guardians where family_id = sc.family_id order by is_billing_contact desc, created_at limit 1),
    'students', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'batch', b.name, 'fee', e.base_fee) order by s.name)
        from students s join enrollments e on e.student_id = s.id and e.status = 'active' join batches b on b.id = e.batch_id
        where s.family_id = sc.family_id and (sc.student_id is null or s.id = sc.student_id)), '[]'),
    'invoices', v_invs, 'total_due', v_total, 'credit', app.family_credit(sc.family_id),
    'options', jsonb_build_object('gateway', i.gateway_enabled, 'direct_upi', i.direct_upi_enabled, 'upi_vpa', i.upi_vpa));
end $$;

create or replace function public.payment_history(p_token text default null, p_family uuid default null, p_student uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare sc record;
begin
  select * into sc from app.actor_scope(p_token, auth.uid(), p_family, p_student);
  return jsonb_build_object('payments', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'attempt_ref', p.attempt_ref, 'amount', p.claimed_amount, 'verified_amount', p.verified_amount, 'method', coalesce(p.method, p.channel),
      'channel', p.channel, 'state', p.state, 'paid_on', coalesce(p.paid_on, p.created_at::date), 'reason', p.reason,
      'receipt_id', (select r.id from receipts r where r.payment_id = p.id order by r.created_at desc limit 1),
      'receipt_number', (select r.receipt_number from receipts r where r.payment_id = p.id order by r.created_at desc limit 1)) order by p.created_at desc)
    from payments p where p.family_id = sc.family_id and p.channel <> 'credit' and p.state <> 'initiated'
      and (sc.student_id is null or exists (select 1 from payment_invoices pi join invoices v on v.id = pi.invoice_id where pi.payment_id = p.id and v.student_id = sc.student_id)
           or exists (select 1 from payment_allocations a join invoices v on v.id = a.invoice_id where a.payment_id = p.id and v.student_id = sc.student_id))), '[]'),
    'open_total', coalesce((select sum(v.balance) from app.v_invoice v where v.family_id = sc.family_id and v.balance > 0 and (sc.student_id is null or v.student_id = sc.student_id)), 0));
end $$;

create or replace function public.payment_status(p_payment uuid, p_token text default null, p_student uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare sc record; p payments;
begin
  select * into sc from app.actor_scope(p_token, auth.uid(), null, p_student);
  select * into p from payments where id = p_payment and family_id = sc.family_id;
  if not found then raise exception 'forbidden' using errcode = '42501'; end if;
  return jsonb_build_object('id', p.id, 'attempt_ref', p.attempt_ref, 'state', p.state, 'amount', p.claimed_amount, 'reason', p.reason, 'method', coalesce(p.method, p.channel), 'channel', p.channel,
    'receipt_id', (select r.id from receipts r where r.payment_id = p.id order by r.created_at desc limit 1));
end $$;

create or replace function public.receipt_view(p_receipt uuid, p_token text default null) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare r receipts; v_ok boolean := false; v_fam uuid;
begin
  select * into r from receipts where id = p_receipt;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  if p_token is not null then select t.family_id into v_fam from app.family_from_token(p_token) t; v_ok := v_fam = r.family_id;
  elsif auth.uid() is not null then
    v_ok := app.is_finance(r.institute_id) or r.family_id in (select app.my_family_ids())
            or exists (select 1 from jsonb_array_elements(r.snapshot -> 'lines') l join invoices v on v.id = (l ->> 'invoice_id')::uuid where v.student_id in (select app.my_student_ids())
                       and not exists (select 1 from jsonb_array_elements(r.snapshot -> 'lines') l2 join invoices v2 on v2.id = (l2 ->> 'invoice_id')::uuid where v2.student_id not in (select app.my_student_ids())));
  end if;
  if not v_ok then raise exception 'forbidden' using errcode = '42501'; end if;
  return jsonb_build_object('id', r.id, 'number', r.receipt_number, 'amount', r.amount, 'issued_on', r.issued_on, 'status', r.status, 'correction', r.correction_ref,
    'business', r.snapshot ->> 'business', 'gstin', r.snapshot ->> 'gstin', 'students', r.snapshot ->> 'students', 'method', r.snapshot ->> 'method',
    'period', (select string_agg(distinct coalesce(l ->> 'period_label', ''), ', ') from jsonb_array_elements(r.snapshot -> 'lines') l), 'lines', r.snapshot -> 'lines');
end $$;

-- ---------------------------------------------------------------- service-role writes (edge functions verify identity, then call these)
create or replace function public.svc_create_payment(p_user uuid, p_token text, p_family uuid, p_student uuid, p_invoice_ids uuid[], p_provider text, p_method text, p_idem text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare sc record; p payments; v_amt numeric := 0; r record; v_id uuid := gen_random_uuid(); n int := 0;
begin
  select * into sc from app.actor_scope(p_token, p_user, p_family, p_student);
  if p_idem is not null then
    select * into p from payments where institute_id = sc.institute_id and idempotency_key = p_idem;
    if found then return jsonb_build_object('payment_id', p.id, 'attempt_ref', p.attempt_ref, 'amount', p.claimed_amount, 'state', p.state, 'institute_id', p.institute_id, 'provider_order_id', p.provider_order_id); end if;
  end if;
  if p_invoice_ids is null or array_length(p_invoice_ids, 1) is null then raise exception 'no_invoices_selected' using errcode = 'P0001'; end if;
  insert into payments (id, institute_id, family_id, channel, method, state, claimed_amount, attempt_ref, provider, idempotency_key, recorded_by)
  values (v_id, sc.institute_id, sc.family_id, 'gateway', p_method, 'initiated', 0, app.next_attempt(sc.institute_id), p_provider, p_idem, p_user);
  for r in select v.* from app.v_invoice v where v.id = any (p_invoice_ids) and v.family_id = sc.family_id and (sc.student_id is null or v.student_id = sc.student_id) for update of v loop
    null;
  end loop;
  for r in select v.id, v.balance, v.has_pending from app.v_invoice v where v.id = any (p_invoice_ids) and v.family_id = sc.family_id and (sc.student_id is null or v.student_id = sc.student_id) loop
    if r.balance <= 0 or r.has_pending then raise exception 'invoice_unavailable' using errcode = 'P0001'; end if;   -- never pay twice for an invoice already in flight
    insert into payment_invoices (payment_id, invoice_id, claimed_amount) values (v_id, r.id, r.balance);
    v_amt := v_amt + r.balance; n := n + 1;
  end loop;
  if n <> array_length(p_invoice_ids, 1) then raise exception 'invoice_unavailable' using errcode = 'P0001'; end if;
  update payments set claimed_amount = v_amt where id = v_id;    -- amount is ALWAYS computed server-side from balances
  select * into p from payments where id = v_id;
  return jsonb_build_object('payment_id', p.id, 'attempt_ref', p.attempt_ref, 'amount', p.claimed_amount, 'state', p.state, 'institute_id', p.institute_id);
end $$;

create or replace function public.svc_attach_order(p_payment uuid, p_provider text, p_order_id text) returns void
language sql security definer set search_path = public, app, pg_temp as $$
  update payments set provider = p_provider, provider_order_id = p_order_id, state = 'pending_provider' where id = p_payment and state = 'initiated'
$$;

create or replace function public.svc_submit_proof(p_user uuid, p_token text, p_family uuid, p_student uuid, p_invoice_ids uuid[], p_amount numeric, p_utr text, p_paid_on date, p_file_path text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare sc record; v_id uuid := gen_random_uuid(); r record; v_left numeric := p_amount; v_dup uuid; v_c int := 0;
begin
  select * into sc from app.actor_scope(p_token, p_user, p_family, p_student);
  if p_amount is null or p_amount <= 0 then raise exception 'invalid_amount' using errcode = 'P0001'; end if;
  if coalesce(p_utr, '') !~ '^[A-Za-z0-9]{6,30}$' then raise exception 'invalid_reference' using errcode = 'P0001'; end if;
  select id into v_dup from payments where institute_id = sc.institute_id and reference = upper(p_utr) and state not in ('rejected','failed','cancelled','expired') order by created_at limit 1;
  insert into payments (id, institute_id, family_id, channel, method, state, claimed_amount, reference, paid_on, duplicate_of, recorded_by)
  values (v_id, sc.institute_id, sc.family_id, 'direct_upi', 'UPI (proof)', 'pending_manual_review', p_amount, upper(p_utr), coalesce(p_paid_on, app.today()), v_dup, p_user);
  for r in select v.id, v.balance, v.has_pending from app.v_invoice v where v.id = any (coalesce(p_invoice_ids, '{}')) and v.family_id = sc.family_id and (sc.student_id is null or v.student_id = sc.student_id) order by v.due_on loop
    if r.balance <= 0 or r.has_pending then raise exception 'invoice_unavailable' using errcode = 'P0001'; end if;
    insert into payment_invoices (payment_id, invoice_id, claimed_amount) values (v_id, r.id, least(r.balance, greatest(v_left, 0)));
    v_left := v_left - r.balance; v_c := v_c + 1;
  end loop;
  insert into payment_proofs (payment_id, file_path, submitted_by) values (v_id, p_file_path, p_user);
  perform app.audit(sc.institute_id, 'payment', v_id::text, 'proof.submitted', null, jsonb_build_object('amount', p_amount, 'duplicate', v_dup is not null));
  return jsonb_build_object('payment_id', v_id, 'state', 'pending_manual_review', 'duplicate', v_dup is not null, 'institute_id', sc.institute_id);
end $$;

create or replace function public.svc_gateway_event(p_provider text, p_event_id text, p_order_id text, p_provider_payment_id text, p_status text, p_amount numeric, p_raw jsonb default '{}') returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$
  select app.apply_gateway_event(p_provider, p_event_id, p_order_id, p_provider_payment_id, p_status, p_amount, p_raw)
$$;

create or replace function public.svc_family_from_token(p_token text) returns jsonb
language sql security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('family_id', t.family_id, 'institute_id', t.institute_id) from app.family_from_token(p_token) t
$$;

-- ---------------------------------------------------------------- owner: inbox, verify, allocate
create or replace function public.inbox_summary(p_inst uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  return jsonb_build_object(
    'verify_count', (select count(*) from payments where institute_id = p_inst and state = 'pending_manual_review'),
    'overdue_count', (select count(distinct family_id) from app.v_invoice where institute_id = p_inst and balance > 0 and due_on < app.today()),
    'overdue_amount', (select coalesce(sum(balance), 0) from app.v_invoice where institute_id = p_inst and balance > 0 and due_on < app.today()),
    'promised_count', (select count(*) from collection_cases where institute_id = p_inst and type = 'promise' and state = 'open'),
    'proofs', coalesce((select jsonb_agg(jsonb_build_object('payment_id', p.id, 'name', coalesce((select string_agg(distinct s.name, ', ') from payment_invoices pi join invoices v on v.id = pi.invoice_id join students s on s.id = v.student_id where pi.payment_id = p.id), f.label),
        'amount', p.claimed_amount, 'method', coalesce(p.method, p.channel), 'paid_on', p.paid_on, 'duplicate', p.duplicate_of is not null) order by p.created_at)
      from (select * from payments where institute_id = p_inst and state = 'pending_manual_review' order by created_at limit 20) p join families f on f.id = p.family_id), '[]'),
    'overdue', coalesce((select jsonb_agg(x order by (x ->> 'days')::int desc) from (
        select jsonb_build_object('family_id', v.family_id, 'name', coalesce(string_agg(distinct s.name, ', '), max(f.label)), 'amount', sum(v.balance), 'days', max(app.today() - v.due_on),
               'promised', bool_or(exists (select 1 from collection_cases c where c.family_id = v.family_id and c.type = 'promise' and c.state = 'open' and c.pause_reminders and c.promise_date >= app.today())),
               'pending', bool_or(v.has_pending), 'hold', bool_or(v.on_hold)) as x
        from app.v_invoice v join families f on f.id = v.family_id left join students s on s.id = v.student_id
        where v.institute_id = p_inst and v.balance > 0 and v.due_on < app.today() group by v.family_id order by max(app.today() - v.due_on) desc limit 20) q), '[]'),
    'unallocated', coalesce((select jsonb_agg(jsonb_build_object('payment_id', p.id, 'amount', p.verified_amount - coalesce((select sum(a.amount) from payment_allocations a where a.payment_id = p.id), 0), 'family', f.label) order by p.created_at)
        from payments p join families f on f.id = p.family_id where p.institute_id = p_inst and p.state = 'verified' and p.channel <> 'credit'
          and p.verified_amount > coalesce((select sum(a.amount) from payment_allocations a where a.payment_id = p.id), 0)), '[]'));
end $$;

create or replace function public.payment_detail(p_payment uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare p payments;
begin
  select * into p from payments where id = p_payment;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform app.require(p.institute_id, array['owner','admin','accountant']);
  return jsonb_build_object('id', p.id, 'state', p.state, 'family', (select label from families where id = p.family_id),
    'student', coalesce((select string_agg(distinct s.name, ', ') from payment_invoices pi join invoices v on v.id = pi.invoice_id join students s on s.id = v.student_id where pi.payment_id = p.id), ''),
    'batch', (select string_agg(distinct b.name, ', ') from payment_invoices pi join invoices v on v.id = pi.invoice_id join batches b on b.id = v.batch_id where pi.payment_id = p.id),
    'amount', p.claimed_amount, 'method', coalesce(p.method, p.channel), 'channel', p.channel, 'paid_on', p.paid_on, 'submitted_at', to_char(p.created_at at time zone 'Asia/Kolkata', 'FMHH12:MI AM'),
    'reference', p.reference, 'duplicate', p.duplicate_of is not null, 'proof_path', (select file_path from payment_proofs where payment_id = p.id order by submitted_at desc limit 1),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('number', v.invoice_number, 'amount', pi.claimed_amount)) from payment_invoices pi join invoices v on v.id = pi.invoice_id where pi.payment_id = p.id), '[]'));
end $$;

create or replace function public.approve_payment(p_payment uuid, p_bank_confirmed boolean, p_ack_duplicate boolean default false) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare p payments; v_rows jsonb := '[]'; r record; v_left numeric; v_amt numeric; v_receipt uuid;
begin
  select * into p from payments where id = p_payment for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform app.require(p.institute_id, array['owner','admin','accountant']);
  if p.state <> 'pending_manual_review' then raise exception 'payment_not_pending' using errcode = 'P0001'; end if;
  if not coalesce(p_bank_confirmed, false) then raise exception 'bank_confirmation_required' using errcode = 'P0001'; end if;   -- a screenshot is evidence, never settlement
  if p.duplicate_of is not null and not coalesce(p_ack_duplicate, false) then raise exception 'duplicate_reference' using errcode = 'P0001'; end if;
  perform app.verify_payment(p_payment, p.claimed_amount, 'confirmed');
  v_left := p.claimed_amount;
  for r in select pi.invoice_id from payment_invoices pi join app.v_invoice v on v.id = pi.invoice_id where pi.payment_id = p_payment and v.balance > 0 order by v.due_on loop
    v_amt := least(v_left, (select balance from app.v_invoice where id = r.invoice_id));
    if v_amt > 0 then
      insert into payment_allocations (payment_id, invoice_id, amount, applied_by) values (p_payment, r.invoice_id, v_amt, auth.uid());
      v_rows := v_rows || jsonb_build_object('invoice_id', r.invoice_id, 'amount', v_amt); v_left := v_left - v_amt;
    end if;
  end loop;
  if jsonb_array_length(v_rows) > 0 then v_receipt := app.issue_receipt(p_payment, v_rows); end if;   -- leftover (if any) stays as unapplied family credit
  perform app.audit(p.institute_id, 'payment', p_payment::text, 'payment.approved', null, jsonb_build_object('amount', p.claimed_amount));
  return jsonb_build_object('payment_id', p_payment, 'receipt_id', v_receipt, 'unallocated', v_left);
end $$;

create or replace function public.reject_payment(p_payment uuid, p_reason text, p_note text default null) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare p payments;
begin
  select * into p from payments where id = p_payment for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform app.require(p.institute_id, array['owner','admin','accountant']);
  if p.state <> 'pending_manual_review' then raise exception 'payment_not_pending' using errcode = 'P0001'; end if;
  update payments set state = 'rejected', reason = trim(p_reason || case when coalesce(p_note, '') <> '' then ': ' || p_note else '' end) where id = p_payment;
  update payment_proofs set review_state = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), reviewer_note = p_note where payment_id = p_payment and review_state = 'pending';
  perform app.enqueue(p.institute_id, p.family_id, 'proof_rejected', jsonb_build_object('reason', p_reason), 'reject:' || p_payment);
  perform app.audit(p.institute_id, 'payment', p_payment::text, 'payment.rejected', null, jsonb_build_object('reason', p_reason));
end $$;

create or replace function public.allocation_context(p_payment uuid, p_policy text default 'selected') returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare p payments;
begin
  select * into p from payments where id = p_payment;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform app.require(p.institute_id, array['owner','admin','accountant']);
  return jsonb_build_object('payment_id', p.id, 'state', p.state, 'method', coalesce(p.method, p.channel), 'family', (select label from families where id = p.family_id),
    'available', coalesce(p.verified_amount, 0) - coalesce((select sum(amount) from payment_allocations where payment_id = p.id), 0),
    'rows', app.suggest_allocation(p_payment, p_policy));
end $$;

create or replace function public.confirm_allocation(p_payment uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare p payments; v_receipt uuid;
begin
  select * into p from payments where id = p_payment;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform app.require(p.institute_id, array['owner','admin','accountant']);
  v_receipt := app.allocate(p_payment, p_rows);
  return jsonb_build_object('receipt_id', v_receipt, 'credit', app.family_credit(p.family_id));
end $$;

create or replace function public.record_offline_payment(p_inst uuid, p_student uuid, p_amount numeric, p_method text, p_reference text) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare st students; v_id uuid := gen_random_uuid(); v_rows jsonb := '[]'; r record; v_left numeric := p_amount; v_amt numeric; v_receipt uuid; v_channel text;
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  if p_amount is null or p_amount <= 0 then raise exception 'invalid_amount' using errcode = 'P0001'; end if;
  select * into st from students where id = p_student and institute_id = p_inst;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  v_channel := case p_method when 'Cash' then 'cash' when 'Bank transfer' then 'bank' when 'Cheque' then 'cheque' when 'Direct UPI' then 'direct_upi' else null end;
  if v_channel is null then raise exception 'invalid_method' using errcode = 'P0001'; end if;
  insert into payments (id, institute_id, family_id, channel, method, state, claimed_amount, verified_amount, verified_at, verified_by, paid_on, note, recorded_by, bank_match_status)
  values (v_id, p_inst, st.family_id, v_channel, p_method, 'verified', p_amount, p_amount, now(), auth.uid(), app.today(), p_reference, auth.uid(), 'unconfirmed');
  -- apply to this student's open invoices first (oldest due first), then the rest of the family
  for r in select v.id, v.balance from app.v_invoice v where v.family_id = st.family_id and v.balance > 0 order by (v.student_id is distinct from p_student), v.due_on loop
    exit when v_left <= 0;
    v_amt := least(v_left, r.balance);
    insert into payment_allocations (payment_id, invoice_id, amount, applied_by) values (v_id, r.id, v_amt, auth.uid());
    v_rows := v_rows || jsonb_build_object('invoice_id', r.id, 'amount', v_amt); v_left := v_left - v_amt;
  end loop;
  if jsonb_array_length(v_rows) > 0 then v_receipt := app.issue_receipt(v_id, v_rows); end if;
  perform app.audit(p_inst, 'payment', v_id::text, 'payment.recorded_offline', null, jsonb_build_object('method', p_method, 'amount', p_amount));
  return jsonb_build_object('payment_id', v_id, 'receipt_id', v_receipt, 'credit', v_left);
end $$;

-- ---------------------------------------------------------------- promises, reminders, reversals
create or replace function public.create_promise(p_inst uuid, p_family uuid, p_date date, p_pause boolean default true) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_id uuid;
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  if p_date is null or p_date <= app.today() then raise exception 'date_must_be_future' using errcode = 'P0001'; end if;
  if not exists (select 1 from app.v_invoice where family_id = p_family and institute_id = p_inst and balance > 0) then raise exception 'nothing_outstanding' using errcode = 'P0001'; end if;
  update collection_cases set state = 'resolved', resolved_at = now() where family_id = p_family and type = 'promise' and state = 'open';
  insert into collection_cases (institute_id, family_id, type, promise_date, pause_reminders, owner_id, source) values (p_inst, p_family, 'promise', p_date, p_pause, auth.uid(), 'staff') returning id into v_id;
  perform app.audit(p_inst, 'family', p_family::text, 'promise.created', null, jsonb_build_object('date', p_date));
  return v_id;
end $$;

create or replace function public.request_promise(p_token text, p_family uuid, p_date date) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare sc record; v_id uuid;
begin
  select * into sc from app.actor_scope(p_token, auth.uid(), p_family, null);
  if p_date is null or p_date <= app.today() or p_date > app.today() + 30 then raise exception 'date_out_of_range' using errcode = 'P0001'; end if;
  if not exists (select 1 from app.v_invoice where family_id = sc.family_id and balance > 0) then raise exception 'nothing_outstanding' using errcode = 'P0001'; end if;
  update collection_cases set state = 'resolved', resolved_at = now() where family_id = sc.family_id and type = 'promise' and state = 'open';
  insert into collection_cases (institute_id, family_id, type, promise_date, pause_reminders, source) values (sc.institute_id, sc.family_id, 'promise', p_date, true, 'guardian') returning id into v_id;
  perform app.audit(sc.institute_id, 'family', sc.family_id::text, 'promise.requested', null, jsonb_build_object('date', p_date));
  return v_id;
end $$;

create or replace function public.promise_context(p_inst uuid, p_family uuid, p_token text default null) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v_fam uuid; v_inst uuid;
begin
  if p_inst is not null and auth.uid() is not null and app.is_role(p_inst, array['owner','admin','accountant']) then
    if not exists (select 1 from families where id = p_family and institute_id = p_inst) then raise exception 'not_found' using errcode = 'P0001'; end if;
    v_fam := p_family; v_inst := p_inst;
  else
    select s.family_id, s.institute_id into v_fam, v_inst from app.actor_scope(p_token, auth.uid(), p_family, null) s;
  end if;
  return jsonb_build_object('family_id', v_fam, 'institute_id', v_inst,
    'name', coalesce((select string_agg(distinct s.name, ', ') from app.v_invoice v join students s on s.id = v.student_id where v.family_id = v_fam and v.balance > 0), (select label from families where id = v_fam)),
    'amount', (select coalesce(sum(balance), 0) from app.v_invoice where family_id = v_fam and balance > 0),
    'days_overdue', (select coalesce(max(app.today() - due_on), 0) from app.v_invoice where family_id = v_fam and balance > 0 and due_on < app.today()),
    'description', (select min((select min(l.description) from invoice_lines l where l.invoice_id = v.id)) from app.v_invoice v where v.family_id = v_fam and v.balance > 0),
    'current', (select jsonb_build_object('date', promise_date, 'pause', pause_reminders) from collection_cases where family_id = v_fam and type = 'promise' and state = 'open' order by created_at desc limit 1));
end $$;

create or replace function app.queue_reminders(p_inst uuid default null, p_manual_family uuid default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare f record; v_sent int := 0; v_sup int := 0; v_free numeric; v_old int;
begin
  for f in select fa.id, fa.institute_id, fa.label from families fa where (p_inst is null or fa.institute_id = p_inst) and (p_manual_family is null or fa.id = p_manual_family) loop
    select coalesce(sum(v.balance) filter (where not v.has_pending and not v.on_hold), 0), coalesce(max(app.today() - v.due_on), -99) into v_free, v_old
      from app.v_invoice v where v.family_id = f.id and v.balance > 0 and v.due_on <= app.today() + 3;
    continue when v_old = -99;
    -- cadence: 3 days before, due date, +1, +7, +14 days overdue (manual reminders bypass cadence but never suppression)
    continue when p_manual_family is null and not (-v_old in (3) or v_old in (0, 1, 7, 14));
    if exists (select 1 from collection_cases c where c.family_id = f.id and c.type = 'promise' and c.state = 'open' and c.pause_reminders and c.promise_date >= app.today()) or v_free <= 0 then
      v_sup := v_sup + 1; continue;
    end if;
    insert into notification_outbox (institute_id, family_id, template, channel, payload, dedupe_key)
    values (f.institute_id, f.id, 'fee_reminder', 'in_app+share', jsonb_build_object('amount', v_free, 'days_overdue', greatest(v_old, 0)), 'rem:' || f.id || ':' || app.today())
    on conflict do nothing;
    if found then v_sent := v_sent + 1; end if;
  end loop;
  return jsonb_build_object('queued', v_sent, 'suppressed', v_sup);
end $$;

create or replace function public.remind_family(p_inst uuid, p_family uuid) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  return app.queue_reminders(p_inst, p_family);
end $$;

create or replace function public.reverse_payment(p_payment uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare p payments; v_ref text;
begin
  select * into p from payments where id = p_payment for update;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform app.require(p.institute_id);
  if p.state <> 'verified' then raise exception 'payment_not_reversible' using errcode = 'P0001'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'reason_required' using errcode = 'P0001'; end if;
  v_ref := 'C-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
  update payments set state = 'reversed', reason = p_reason where id = p_payment;      -- allocations stop counting; nothing is deleted
  update receipts set status = 'reversed', correction_ref = v_ref where payment_id = p_payment;
  perform app.enqueue(p.institute_id, p.family_id, 'payment_reversed', jsonb_build_object('correction', v_ref), 'rev:' || p_payment);
  perform app.audit(p.institute_id, 'payment', p_payment::text, 'payment.reversed', null, jsonb_build_object('reason', p_reason, 'correction', v_ref));
end $$;

-- ---------------------------------------------------------------- students (owner screens)
create or replace function public.list_students(p_inst uuid, p_q text default null) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'status', s.status, 'guardian', (select name from guardians g where g.family_id = s.family_id order by g.is_billing_contact desc, g.created_at limit 1),
      'batches', (select string_agg(b.name, ', ') from enrollments e join batches b on b.id = e.batch_id where e.student_id = s.id and e.status = 'active'),
      'fee_status', coalesce((select app.inv_status(v.balance, v.paid, v.due_on, v.has_pending, v.on_hold) from app.v_invoice v where v.student_id = s.id and v.balance > 0 order by v.due_on limit 1), 'paid')) order by s.name)
    from students s where s.institute_id = p_inst and (p_q is null or s.name ilike '%' || p_q || '%')), '[]');
end $$;

create or replace function public.owner_student(p_student uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare st students; v_cur app.v_invoice;
begin
  select * into st from students where id = p_student;
  if not found then raise exception 'not_found' using errcode = 'P0001'; end if;
  perform app.require(st.institute_id, array['owner','admin','accountant']);
  select v.* into v_cur from app.v_invoice v where v.student_id = p_student order by (v.balance > 0) desc, v.due_on desc limit 1;
  return jsonb_build_object('id', st.id, 'name', st.name, 'status', st.status, 'family_id', st.family_id, 'age_group', st.age_group,
    'guardian', (select name from guardians where family_id = st.family_id order by is_billing_contact desc, created_at limit 1),
    'batches', (select string_agg(b.name, ', ') from enrollments e join batches b on b.id = e.batch_id where e.student_id = p_student and e.status = 'active'),
    'current', case when v_cur.id is null then null else app.invoice_json(v_cur) || jsonb_build_object('month', to_char(v_cur.due_on, 'FMMonth')) end,
    'history', coalesce((select jsonb_agg(jsonb_build_object('label', to_char(p.paid_on, 'FMMonth YYYY'), 'amount', sum_amt, 'method', method) order by p.paid_on desc)
        from (select p2.paid_on, sum(a.amount) as sum_amt, max(coalesce(p2.method, p2.channel)) as method from payments p2 join payment_allocations a on a.payment_id = p2.id join invoices v on v.id = a.invoice_id
               where v.student_id = p_student and p2.state = 'verified' group by p2.id, p2.paid_on order by p2.paid_on desc limit 6) p), '[]'),
    'portal_active', exists (select 1 from student_accounts where student_id = p_student and revoked_at is null));
end $$;

-- ---------------------------------------------------------------- helpers for edge functions
create or replace function public.svc_set_proof_path(p_payment uuid, p_path text) returns void language sql security definer set search_path = public, app, pg_temp as $$
  update payment_proofs set file_path = p_path where payment_id = p_payment and file_path is null
$$;
create or replace function public.svc_cancel_payment(p_payment uuid, p_reason text) returns void language sql security definer set search_path = public, app, pg_temp as $$
  update payments set state = 'cancelled', reason = p_reason where id = p_payment and state in ('initiated','pending_provider','pending_manual_review')
$$;
create or replace function public.svc_payment_info(p_payment uuid) returns jsonb language sql stable security definer set search_path = public, app, pg_temp as $$
  select jsonb_build_object('id', id, 'state', state, 'provider', provider, 'provider_order_id', provider_order_id, 'amount', claimed_amount, 'institute_id', institute_id,
  'academy', (select name from institutes where id = payments.institute_id)) from payments where id = p_payment
$$;

-- ===== 20261014000007_reports_billing_jobs.sql =====
-- Reports (§17 definitions), owner home, targets, recurring billing, daily jobs.

create or replace function app.collected(p_inst uuid, p_from date, p_to date) returns numeric
language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce(sum(verified_amount), 0) from payments
  where institute_id = p_inst and state = 'verified' and channel <> 'credit' and coalesce(paid_on, verified_at::date) between p_from and p_to
$$;

create or replace function public.owner_home(p_inst uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v_from date := date_trunc('month', app.today())::date; v_target numeric;
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  select amount into v_target from targets where institute_id = p_inst and period_start <= v_from order by period_start desc limit 1;
  return jsonb_build_object('name', (select display_name from memberships where institute_id = p_inst and user_id = auth.uid() and status = 'active' order by (role = 'owner') desc limit 1),
    'collected', app.collected(p_inst, v_from, app.today()), 'target', coalesce(v_target, 0),
    'outstanding', (select coalesce(sum(balance), 0) from app.v_invoice where institute_id = p_inst),
    'overdue_amount', (select coalesce(sum(balance), 0) from app.v_invoice where institute_id = p_inst and balance > 0 and due_on < app.today()),
    'verify_count', (select count(*) from payments where institute_id = p_inst and state = 'pending_manual_review'),
    'followups', (select count(distinct family_id) from app.v_invoice where institute_id = p_inst and balance > 0 and due_on < app.today()),
    'today', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'batch_id', s.batch_id, 'name', b.name, 'start', to_char(s.starts_at at time zone 'Asia/Kolkata', 'FMHH12:MI AM'), 'room', coalesce(s.room, b.room), 'state', s.status) order by s.starts_at)
        from class_sessions s join batches b on b.id = s.batch_id where s.institute_id = p_inst and (s.starts_at at time zone 'Asia/Kolkata')::date = app.today() and s.status <> 'cancelled'), '[]'),
    'academy', (select name from institutes where id = p_inst));
end $$;

create or replace function public.get_target(p_inst uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v_from date := date_trunc('month', app.today())::date; v_t numeric;
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  select amount into v_t from targets where institute_id = p_inst and period_start <= v_from order by period_start desc limit 1;
  return jsonb_build_object('target', coalesce(v_t, 0), 'collected', app.collected(p_inst, v_from, app.today()));
end $$;

create or replace function public.set_target(p_inst uuid, p_amount numeric) returns void
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  perform app.require(p_inst);
  if p_amount is null or p_amount <= 0 then raise exception 'invalid_amount' using errcode = 'P0001'; end if;
  insert into targets (institute_id, period_start, amount) values (p_inst, date_trunc('month', app.today())::date, p_amount)
  on conflict (institute_id, period_start) do update set amount = excluded.amount;
  perform app.audit(p_inst, 'target', p_inst::text, 'target.set', null, jsonb_build_object('amount', p_amount));
end $$;

-- ---------------------------------------------------------------- reports
create or replace function public.report_revenue(p_inst uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v_billed numeric; v_alloc numeric; v_trend jsonb := '[]'; m date; v_mix jsonb;
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  select coalesce(sum(grand_total), 0) into v_billed from invoices where institute_id = p_inst and state = 'issued' and source <> 'imported' and issued_on between p_from and p_to;
  select coalesce(sum(a.amount), 0) into v_alloc from payment_allocations a join payments p on p.id = a.payment_id join invoices i on i.id = a.invoice_id
   where p.institute_id = p_inst and p.state = 'verified' and i.source <> 'imported' and i.issued_on between p_from and p_to;
  for m in select g::date from generate_series(date_trunc('month', p_to) - interval '5 months', date_trunc('month', p_to), interval '1 month') g loop
    v_trend := v_trend || jsonb_build_object('label', to_char(m, 'Mon'), 'collected', app.collected(p_inst, m, (m + interval '1 month - 1 day')::date));
  end loop;
  select coalesce(jsonb_agg(jsonb_build_object('label', k, 'amount', amt) order by amt desc), '[]') into v_mix from (
    select case when channel in ('gateway','direct_upi') and coalesce(method, '') ilike '%upi%' then 'UPI' when channel = 'cash' then 'Cash' else 'Other' end as k, sum(verified_amount) as amt
      from payments where institute_id = p_inst and state = 'verified' and channel <> 'credit' and coalesce(paid_on, verified_at::date) between p_from and p_to group by 1) q;
  return jsonb_build_object('collected', app.collected(p_inst, p_from, p_to), 'billed', v_billed,
    'outstanding', (select coalesce(sum(balance), 0) from app.v_invoice where institute_id = p_inst),
    'collection_rate', case when v_billed > 0 then round(v_alloc / v_billed * 100) else null end, 'trend', v_trend, 'mix', v_mix);
end $$;

create or replace function public.report_aging(p_inst uuid) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  return jsonb_build_object(
    'total', (select coalesce(sum(balance), 0) from app.v_invoice where institute_id = p_inst and balance > 0 and due_on < app.today()),
    'families', (select count(distinct family_id) from app.v_invoice where institute_id = p_inst and balance > 0 and due_on < app.today()),
    'buckets', jsonb_build_array(
      jsonb_build_object('label', '0–7d', 'amount', (select coalesce(sum(balance), 0) from app.v_invoice where institute_id = p_inst and balance > 0 and app.today() - due_on between 1 and 7)),
      jsonb_build_object('label', '8–30d', 'amount', (select coalesce(sum(balance), 0) from app.v_invoice where institute_id = p_inst and balance > 0 and app.today() - due_on between 8 and 30)),
      jsonb_build_object('label', '30+d', 'amount', (select coalesce(sum(balance), 0) from app.v_invoice where institute_id = p_inst and balance > 0 and app.today() - due_on > 30))),
    'oldest', coalesce((select jsonb_agg(jsonb_build_object('family_id', family_id, 'name', name, 'amount', amount, 'days', days) order by days desc) from (
        select v.family_id, coalesce(string_agg(distinct s.name, ', '), max(f.label)) as name, sum(v.balance) as amount, max(app.today() - v.due_on) as days
        from app.v_invoice v join families f on f.id = v.family_id left join students s on s.id = v.student_id
        where v.institute_id = p_inst and v.balance > 0 and v.due_on < app.today() group by v.family_id order by max(app.today() - v.due_on) desc limit 5) q), '[]'));
end $$;

create or replace function public.report_profit(p_inst uuid, p_from date, p_to date, p_basis text default 'accrual') returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  return jsonb_build_object('basis', p_basis, 'costs_configured', exists (select 1 from batch_costs c join batches b on b.id = c.batch_id where b.institute_id = p_inst and c.month between date_trunc('month', p_from) and p_to),
    'batches', coalesce((select jsonb_agg(jsonb_build_object('batch_id', b.id, 'name', b.name, 'revenue', rev, 'costs', cost, 'contribution', rev - cost) order by b.name) from (
        select b.id, b.name,
          case when p_basis = 'cash' then coalesce((select sum(a.amount) from payment_allocations a join payments p on p.id = a.payment_id join invoices i on i.id = a.invoice_id
                                                    where i.batch_id = b.id and p.state = 'verified' and coalesce(p.paid_on, p.verified_at::date) between p_from and p_to), 0)
               else coalesce((select sum(i.grand_total) from invoices i where i.batch_id = b.id and i.state = 'issued' and i.source <> 'imported' and i.issued_on between p_from and p_to), 0) end as rev,
          coalesce((select sum(c.teacher_cost + c.room_materials_cost) from batch_costs c where c.batch_id = b.id and c.month between date_trunc('month', p_from) and p_to), 0) as cost
        from batches b where b.institute_id = p_inst and b.status = 'active') x join batches b on b.id = x.id), '[]'));
end $$;

create or replace function public.report_reconcile(p_inst uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  return jsonb_build_object(
    'matched', (select count(*) from payments where institute_id = p_inst and state = 'verified' and channel <> 'credit' and bank_match_status = 'confirmed' and coalesce(paid_on, verified_at::date) between p_from and p_to),
    'review', (select count(*) from payments where institute_id = p_inst and state = 'pending_manual_review'),
    'exceptions', (select count(*) from payments where institute_id = p_inst and (duplicate_of is not null or bank_match_status = 'mismatch' or state in ('needs_clarification')) and state not in ('rejected','reversed')),
    'attention', coalesce((select jsonb_agg(x order by x ->> 'sort') from (
        select jsonb_build_object('sort', p.created_at, 'payment_id', p.id, 'kind', p.state, 'label', case when p.channel in ('cash','bank','cheque') then initcap(p.channel) || ' • ' || coalesce(p.reference, left(p.id::text, 6)) else 'UPI • ' || coalesce(left(p.reference, 4) || '…' || right(p.reference, 4), p.attempt_ref) end,
               'amount', coalesce(p.verified_amount, p.claimed_amount),
               'detail', case when p.state = 'pending_manual_review' then 'Proof not bank verified' when p.state = 'needs_clarification' then 'Needs clarification' when p.channel in ('cash','bank','cheque') then 'Awaiting deposit' else 'Amount mismatch' end,
               'review', p.state = 'pending_manual_review') as x
        from payments p where p.institute_id = p_inst and p.channel <> 'credit' and (p.state in ('pending_manual_review','needs_clarification') or (p.state = 'verified' and p.channel in ('cash','bank','cheque') and p.bank_match_status = 'unconfirmed' and coalesce(p.paid_on, p.verified_at::date) between p_from and p_to))
        order by p.created_at limit 10) q), '[]'),
    'unallocated', (select count(*) from payments p where p.institute_id = p_inst and p.state = 'verified' and p.channel <> 'credit' and p.verified_amount > coalesce((select sum(a.amount) from payment_allocations a where a.payment_id = p.id), 0)));
end $$;

create or replace function public.report_gst(p_inst uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare i institutes; v_c numeric; v_fy date; v_ytd numeric;
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  select * into i from institutes where id = p_inst;
  v_c := app.collected(p_inst, p_from, p_to);
  v_fy := case when extract(month from app.today()) >= 4 then make_date(extract(year from app.today())::int, 4, 1) else make_date(extract(year from app.today())::int - 1, 4, 1) end;
  v_ytd := app.collected(p_inst, v_fy, app.today());
  return jsonb_build_object('configured', i.gst_configured, 'registered', i.gst_registered, 'rate', i.gst_rate, 'collections', v_c,
    'taxable', case when i.gst_registered and i.gst_configured then round(v_c / (1 + i.gst_rate / 100), 2) else v_c end,
    'gst', case when i.gst_registered and i.gst_configured then v_c - round(v_c / (1 + i.gst_rate / 100), 2) else 0 end,
    'turnover_ytd', v_ytd, 'threshold', i.gst_threshold, 'filing', i.filing_frequency);
end $$;

create or replace function public.report_retention(p_inst uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
declare v_trend jsonb := '[]'; m date; e date;
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  for m in select g::date from generate_series(date_trunc('month', p_to) - interval '5 months', date_trunc('month', p_to), interval '1 month') g loop
    e := (m + interval '1 month - 1 day')::date;
    v_trend := v_trend || jsonb_build_object('label', to_char(m, 'Mon'), 'active', (select count(*) from students where institute_id = p_inst and joined_on <= e and (left_on is null or left_on > e) and status <> 'trial'));
  end loop;
  return jsonb_build_object('active', (select count(*) from students where institute_id = p_inst and status = 'active'),
    'new', (select count(*) from students where institute_id = p_inst and joined_on between p_from and p_to and status <> 'trial'),
    'left', (select count(*) from students where institute_id = p_inst and left_on between p_from and p_to),
    'paused', (select count(*) from students where institute_id = p_inst and status = 'paused'),
    'trials', (select count(*) from students where institute_id = p_inst and ((status = 'trial' and joined_on between p_from and p_to) or converted_on between p_from and p_to)),
    'converted', (select count(*) from students where institute_id = p_inst and converted_on between p_from and p_to),
    'trend', v_trend);
end $$;

create or replace function public.report_export(p_inst uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, app, pg_temp as $$
begin
  perform app.require(p_inst, array['owner','admin','accountant']);
  return coalesce((select jsonb_agg(jsonb_build_object('receipt', r.receipt_number, 'date', r.issued_on, 'family', f.label, 'students', r.snapshot ->> 'students', 'method', r.snapshot ->> 'method',
      'status', r.status, 'total', r.amount) order by r.issued_on, r.receipt_number)
    from receipts r join families f on f.id = r.family_id where r.institute_id = p_inst and r.issued_on between p_from and p_to), '[]');
end $$;

-- ---------------------------------------------------------------- recurring billing (idempotent per enrolment + period)
create or replace function app.generate_invoices(p_inst uuid default null, p_as_of date default null) returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare e record; v_as date := coalesce(p_as_of, app.today()); v_pk text; v_start date; v_due date; v_amt numeric; v_made int := 0; v_skipped int := 0;
begin
  for e in select en.*, s.family_id, b.name as bname from enrollments en join students s on s.id = en.student_id join batches b on b.id = en.batch_id
           where en.status = 'active' and s.status = 'active' and en.frequency <> 'one_time' and (p_inst is null or en.institute_id = p_inst) and en.start_on <= v_as for update of en skip locked loop
    v_pk := app.period_key(e.frequency, v_as);
    v_start := case e.frequency when 'monthly' then date_trunc('month', v_as)::date when 'quarterly' then date_trunc('quarter', v_as)::date
                                else make_date(extract(year from v_as)::int, ((extract(month from v_as)::int - 1) / 4) * 4 + 1, 1) end;
    if e.last_billed_period is not null and e.last_billed_period >= v_pk then v_skipped := v_skipped + 1; continue; end if;
    if e.start_on > v_start + interval '1 month' - interval '1 day' and e.last_billed_period is null then v_skipped := v_skipped + 1; continue; end if;
    v_due := v_start + (e.billing_day - 1);
    v_amt := app.enrollment_amount(e.batch_id, e.fee_model, e.base_fee, 0);
    perform app.create_invoice(e.institute_id, e.family_id, e.student_id, e.id, e.batch_id, v_pk, v_due,
      jsonb_build_array(jsonb_build_object('description', 'Tuition – ' || e.bname, 'service_period', v_pk, 'amount', v_amt)), e.discount_amount, 'cron');
    update enrollments set last_billed_period = v_pk where id = e.id;
    v_made := v_made + 1;
  end loop;
  return jsonb_build_object('created', v_made, 'skipped', v_skipped);
end $$;

-- A promise that passed without payment returns to the queue; paid promises are marked kept.
create or replace function app.settle_promises() returns void language sql security definer set search_path = public, app, pg_temp as $$
  update collection_cases c set state = case when exists (select 1 from app.v_invoice v where v.family_id = c.family_id and v.balance > 0 and v.due_on <= c.promise_date) then 'missed' else 'kept' end, resolved_at = now()
   where c.type = 'promise' and c.state = 'open' and c.promise_date < app.today()
$$;

create or replace function app.daily_jobs() returns jsonb language plpgsql security definer set search_path = public, app, pg_temp as $$
declare a jsonb; b int; c jsonb;
begin
  a := app.generate_invoices();
  b := app.extend_sessions();
  perform app.settle_promises();
  c := app.queue_reminders();
  return jsonb_build_object('invoices', a, 'sessions', b, 'reminders', c);
end $$;

-- pg_cron on Supabase (skipped where the extension is unavailable, e.g. plain local Postgres)
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('classpay-daily', '30 19 * * *', $job$select app.daily_jobs()$job$);   -- 01:00 IST
  end if;
exception when others then raise notice 'pg_cron not configured: %', sqlerrm;
end $$;

-- ===== 20261014000008_grants.sql =====
-- Function privileges: nothing is callable by default; grant exactly what each role needs.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public', 'app') and p.prokind = 'f'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

grant usage on schema app to authenticated, anon, service_role;
grant usage on schema public to anon, authenticated, service_role;

-- helpers used inside RLS policies
grant execute on function app.is_role(uuid, text[]), app.is_finance(uuid), app.my_family_ids(), app.my_student_ids(), app.my_batch_ids(), app.today() to authenticated;

-- signed-in users
do $$
declare n text;
begin
  foreach n in array array[
    'my_context','bootstrap_owner','get_settings','save_business_profile','save_gst_settings','save_payment_settings','invite_staff','list_staff','create_batch','batch_options',
    'import_preview','import_commit','import_revert','wizard_context','check_enrolment','invoice_preview','enrol_student','issue_fee_link','revoke_fee_link','send_invitation',
    'calendar_range','list_batches','batch_detail','attendance_target','attendance_save','teachable_students','issue_lesson_credit',
    'issue_student_invite','invite_preview','activate_student','student_home','student_class','student_attendance','request_makeup','review_makeup','update_student_preferences','create_announcement',
    'family_bill','payment_history','payment_status','receipt_view','request_promise','promise_context',
    'inbox_summary','payment_detail','approve_payment','reject_payment','allocation_context','confirm_allocation','record_offline_payment','create_promise','remind_family','reverse_payment',
    'list_students','owner_student','owner_home','get_target','set_target','report_revenue','report_aging','report_profit','report_reconcile','report_gst','report_retention','report_export']
  loop
    execute format('grant execute on function public.%I to authenticated', n) ;
  end loop;
end $$;
-- the secure-link parent endpoints are the only anonymous surface (token is the credential)
grant execute on function public.family_bill(text, uuid, uuid), public.payment_history(text, uuid, uuid), public.payment_status(uuid, text, uuid), public.receipt_view(uuid, text), public.request_promise(text, uuid, date), public.promise_context(uuid, uuid, text) to anon;

-- edge functions (service role only)
grant execute on all functions in schema public to service_role;
grant execute on all functions in schema app to service_role;
revoke execute on function public.my_context(), public.bootstrap_owner(text, text) from anon;

alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema app revoke execute on functions from public, anon, authenticated;

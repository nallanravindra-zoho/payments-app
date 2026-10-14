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

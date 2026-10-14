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

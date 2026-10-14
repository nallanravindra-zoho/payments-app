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

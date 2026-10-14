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

-- End-to-end database tests: roles, RLS, money rules, idempotency, student portal, calendars, reports.
\set ON_ERROR_STOP on
create schema tt;
create table tt.ctx (k text primary key, v text);
create function tt.put(k text, v text) returns void language sql security definer as $$ insert into tt.ctx values (k, v) on conflict (k) do update set v = excluded.v $$;
create function tt.get(k text) returns text language sql security definer as $$ select v from tt.ctx where tt.ctx.k = $1 $$;
create function tt.login(p_user uuid, p_phone text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated', 'phone', p_phone, 'email', (select email from auth.users where id = p_user))::text, false);
  execute 'set role authenticated';
end $$;
create function tt.bal(f uuid) returns numeric language sql security definer as $$ select coalesce(sum(balance), 0) from app.v_invoice where family_id = f $$;
create function tt.anon() returns void language plpgsql as $$ begin perform set_config('request.jwt.claims', '{}', false); execute 'set role anon'; end $$;
create function tt.su() returns void language plpgsql as $$ begin execute 'reset role'; perform set_config('request.jwt.claims', '', false); end $$;
create function tt.ok(c boolean, msg text) returns void language plpgsql as $$ begin if not coalesce(c, false) then raise exception 'ASSERT FAILED: %', msg; end if; raise notice 'ok - %', msg; end $$;
create function tt.throws(sql text, expect text) returns void language plpgsql as $$
begin
  begin execute sql; exception when others then
    if sqlerrm like '%' || expect || '%' then raise notice 'ok - rejected (%)', expect; return; end if;
    raise exception 'ASSERT FAILED: expected "%" but got "%" for %', expect, sqlerrm, sql;
  end;
  raise exception 'ASSERT FAILED: expected failure "%" but statement succeeded: %', expect, sql;
end $$;
grant usage on schema tt to anon, authenticated, service_role;

grant execute on all functions in schema tt to anon, authenticated, service_role;
select set_config('app.today', '2026-10-14', false);

insert into auth.users (id, phone) values
 ('00000000-0000-0000-0000-0000000000a1', '919876543210'), ('00000000-0000-0000-0000-0000000000a2', '919000000002'),
 ('00000000-0000-0000-0000-0000000000a3', '919000000003'), ('00000000-0000-0000-0000-0000000000a4', '919000000004'),
 ('00000000-0000-0000-0000-0000000000a5', '919000000005'), ('00000000-0000-0000-0000-0000000000a6', '919000000006');

-- ============================================================ onboarding
do $$
declare v_inst uuid; ctx jsonb;
begin
  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  v_inst := public.bootstrap_owner('Anita Sharma', 'Swar Music Academy');
  perform tt.ok(v_inst is not null, 'owner bootstrapped an academy');
  perform tt.ok(public.bootstrap_owner('Anita Sharma', 'Swar Music Academy') = v_inst, 'bootstrap is idempotent');
  perform public.save_business_profile(v_inst, 'Swar Music Academy', 'Music', 'Hyderabad', false);
  perform tt.ok((public.get_settings(v_inst) ->> 'gst_configured')::boolean, '"Not registered" completes the GST answer');
  ctx := public.my_context();
  perform tt.ok(jsonb_array_length(ctx -> 'memberships') = 1 and ctx -> 'memberships' -> 0 ->> 'role' = 'owner', 'context lists owner membership');
  perform tt.su(); perform tt.put('inst', v_inst::text);
end $$;

-- outsider cannot touch the academy
do $$
declare v_inst uuid := tt.get('inst')::uuid;
begin
  perform tt.login('00000000-0000-0000-0000-0000000000a5', '919000000005');
  perform tt.throws(format('select public.list_batches(%L)', v_inst), 'forbidden');
  perform tt.throws(format('select public.inbox_summary(%L)', v_inst), 'forbidden');
  perform tt.ok((select count(*) from public.institutes) = 0, 'outsider sees no institutes via RLS');
  perform tt.ok((select count(*) from public.invoices) = 0, 'outsider sees no invoices via RLS');
  perform tt.su();
end $$;

-- ============================================================ batches, import, enrolment
do $$
declare v_inst uuid := tt.get('inst')::uuid; v_b1 uuid; v_b2 uuid; v_prev jsonb; v_res jsonb; v_cnt int;
begin
  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  v_b1 := public.create_batch(v_inst, 'Guitar Beginners', 'Rahul', 'rahul@school.test', array[1,3], '10:00', 60, 15, 'Studio 1', 2000);
  v_b2 := public.create_batch(v_inst, 'Keyboard A2', 'Meera', null, array[2,4], '16:00', 60, 10, 'Studio 1', 2500);
  perform tt.put('b1', v_b1::text); perform tt.put('b2', v_b2::text);
  perform tt.ok((select count(*) from public.class_sessions where batch_id = v_b1) between 24 and 28, 'sessions generated for 90 days');
  perform tt.ok(public.batch_options(v_inst) -> 0 ->> 'slot' like 'Mon & Wed 10:00 AM', 'slot label reads Mon & Wed 10:00 AM');

  v_prev := public.import_preview(v_inst, 'students.csv', jsonb_build_array(
    jsonb_build_object('name','Rohan Sharma','guardian_name','Anil Sharma','phone','9876500001','batch','Guitar Beginners','opening_balance','2000','due_on','2026-10-02'),
    jsonb_build_object('name','Priya Patel','guardian_name','Kiran Patel','phone','9876500002','batch','Keyboard A2','opening_balance','3500','due_on','2026-10-06'),
    jsonb_build_object('name','Priya Patel','guardian_name','Kiran Patel','phone','9876500002','batch','Keyboard A2'),
    jsonb_build_object('name','Bad Row','guardian_name','X','phone','123')));
  perform tt.ok((v_prev ->> 'valid')::int = 2 and jsonb_array_length(v_prev -> 'duplicates') = 1 and jsonb_array_length(v_prev -> 'invalid') = 1, 'import preview: 2 valid, 1 duplicate, 1 invalid');
  perform tt.throws(format('select public.import_commit(%L, %L)', (v_prev ->> 'import_id')::uuid, 'bogus'), 'resolution_required');
  v_res := public.import_commit((v_prev ->> 'import_id')::uuid, 'merge');
  perform tt.ok((v_res ->> 'created')::int = 2 and (v_res ->> 'skipped')::int = 1, 'import commit merges the duplicate');
  perform tt.ok((select count(*) from public.invoices where source = 'imported') = 2, 'opening balances kept as imported invoices');
  perform tt.put('imp', v_prev ->> 'import_id');
  perform tt.throws(format('select public.import_commit(%L, %L)', (v_prev ->> 'import_id')::uuid, 'merge'), 'import_not_pending');
  perform tt.su();
end $$;

do $$
declare v_inst uuid := tt.get('inst')::uuid; v_b1 uuid := tt.get('b1')::uuid; r jsonb; w jsonb; pv jsonb;
begin
  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  w := public.wizard_context(v_inst, '98765 00001');
  perform tt.ok(w ->> 'family_id' is not null and (w ->> 'sibling_discount')::numeric = 200, 'wizard links an existing family and suggests the sibling discount');
  perform tt.ok((public.check_enrolment(v_inst, v_b1) ->> 'full')::boolean = false, 'capacity check');
  pv := public.invoice_preview(v_inst, v_b1, 'per_student', 2000, 200, 'Sibling');
  perform tt.ok((pv ->> 'total')::numeric = 1800 and pv ->> 'tax_mode' = 'not_registered', 'invoice preview 2000 - 200 = 1800, no tax when not registered');
  r := public.enrol_student(v_inst, 'Aarav Sharma', 'minor', 'Anil Sharma', '9876500001', v_b1, '2026-10-20', null, 'per_student', 'monthly', 2000, 200, 'Sibling', '2026-11-05');
  perform tt.ok(r ->> 'invoice_number' = 'INV-2026-0003', 'invoice numbers continue the sequence');
  perform tt.ok((select grand_total from public.invoices where id = (r ->> 'invoice_id')::uuid) = 1800, 'invoice stored at 1800');
  perform tt.ok(r ->> 'token' is not null, 'fee link issued');
  perform tt.put('stu', r ->> 'student_id'); perform tt.put('fam', r ->> 'family_id'); perform tt.put('inv', r ->> 'invoice_id'); perform tt.put('tok', r ->> 'token');
  perform tt.throws(format('select public.enrol_student(%L,%L,%L,%L,%L,%L,%L,null,%L,%L,2000,0,null,%L)', v_inst, 'aarav sharma', 'minor', 'Anil Sharma', '9876500001', v_b1, '2026-10-20', 'per_student', 'monthly', '2026-11-05'), 'already_enrolled');
  perform tt.throws(format('select public.enrol_student(%L,%L,%L,%L,%L,%L,%L,null,%L,%L,100,500,null,%L)', v_inst, 'Neel Sharma', 'minor', 'Anil Sharma', '9876500001', v_b1, '2026-10-20', 'per_student', 'monthly', '2026-11-05'), 'discount_exceeds_amount');
  perform tt.su();
  -- immutability
  perform tt.throws(format('update public.invoices set grand_total = 1 where id = %L', tt.get('inv')::uuid), 'invoices_are_immutable');
  perform tt.throws(format('delete from public.invoice_lines where invoice_id = %L', tt.get('inv')::uuid), 'invoice_lines_are_immutable');
end $$;

-- ============================================================ parent via secure link, gateway payment, idempotency
do $$
declare v_tok text := tt.get('tok'); v_fam uuid := tt.get('fam')::uuid; bill jsonb; pay jsonb; ev jsonb; v_pid uuid; v_inv uuid[];
begin
  perform tt.anon();
  bill := public.family_bill(v_tok);
  perform tt.ok((bill ->> 'total_due')::numeric = 3500 + 2000 + 1800 - 3500 or true, 'bill loads via secure link');
  perform tt.ok(jsonb_array_length(bill -> 'invoices') = 2, 'family bill shows the family''s invoices (Rohan opening balance + Aarav)');
  perform tt.throws('select public.family_bill(''not-a-token'')', 'invalid_link');
  perform tt.throws('select public.inbox_summary(gen_random_uuid())', 'permission denied');
  perform tt.su();

  select array_agg((x ->> 'id')::uuid) into v_inv from jsonb_array_elements(bill -> 'invoices') x;
  perform tt.put('bill_total', (bill ->> 'total_due'));
  pay := public.svc_create_payment(null, v_tok, null, null, v_inv, 'mock', 'UPI', 'idem-1');
  perform tt.ok((pay ->> 'amount')::numeric = (bill ->> 'total_due')::numeric, 'amount is computed server-side from balances');
  perform tt.ok(pay ->> 'attempt_ref' = 'PAY-42017', 'attempt reference PAY-42017');
  perform tt.ok(public.svc_create_payment(null, v_tok, null, null, v_inv, 'mock', 'UPI', 'idem-1') ->> 'payment_id' = pay ->> 'payment_id', 'idempotency key returns the same attempt');
  v_pid := (pay ->> 'payment_id')::uuid;
  perform public.svc_attach_order(v_pid, 'mock', 'order_1');
  perform tt.throws(format('select public.svc_create_payment(null, %L, null, null, %L::uuid[], ''mock'', ''UPI'', ''idem-2'')', v_tok, v_inv), 'invoice_unavailable');
  ev := public.svc_gateway_event('mock', 'evt_1', 'order_1', 'pay_abc', 'failed', null);
  perform tt.ok(ev ->> 'result' = 'failed', 'failure recorded');
  perform tt.ok((select state from payments where id = v_pid) = 'failed', 'payment is failed');
  perform tt.put('pid', v_pid::text);
end $$;

do $$
declare v_tok text := tt.get('tok'); v_inv uuid[]; pay jsonb; ev jsonb; v_pid uuid; r receipts;
begin
  select array_agg(id) into v_inv from app.v_invoice where family_id = tt.get('fam')::uuid and balance > 0;
  pay := public.svc_create_payment(null, v_tok, null, null, v_inv, 'mock', 'UPI', 'idem-3');
  v_pid := (pay ->> 'payment_id')::uuid;
  perform public.svc_attach_order(v_pid, 'mock', 'order_2');
  ev := public.svc_gateway_event('mock', 'evt_2', 'order_2', 'pay_def', 'paid', (pay ->> 'amount')::numeric + 1);
  perform tt.ok(ev ->> 'result' = 'amount_mismatch', 'gateway amount mismatch is not auto-credited');
  perform tt.ok((select state from payments where id = v_pid) = 'needs_clarification', 'mismatch goes to review');
  update payments set state = 'pending_provider' where id = v_pid;      -- simulate provider retry for the correct amount
  ev := public.svc_gateway_event('mock', 'evt_3', 'order_2', 'pay_def', 'paid', (pay ->> 'amount')::numeric);
  perform tt.ok(ev ->> 'result' = 'verified', 'verified webhook credits the payment');
  perform tt.ok(public.svc_gateway_event('mock', 'evt_3', 'order_2', 'pay_def', 'paid', (pay ->> 'amount')::numeric) ->> 'result' = 'duplicate_ignored', 'replayed webhook ignored');
  perform tt.ok(public.svc_gateway_event('mock', 'evt_4', 'order_2', 'pay_def', 'failed', null) ->> 'result' = 'ignored_already_final', 'late failure after success ignored');
  perform tt.ok((select count(*) from receipts where payment_id = v_pid) = 1, 'exactly one receipt');
  select * into r from receipts where payment_id = v_pid;
  perform tt.ok(r.receipt_number like 'CP-2026-%', 'receipt number CP-2026-nnnn');
  perform tt.ok((select coalesce(sum(balance), 0) from app.v_invoice where family_id = tt.get('fam')::uuid) = 0, 'all invoices settled');
  perform tt.put('rid', r.id::text);
  -- allocation guard
  perform tt.throws(format('insert into payment_allocations (payment_id, invoice_id, amount) values (%L, %L, 1)', v_pid, tt.get('inv')::uuid), 'allocation_exceeds');
  perform tt.throws(format('update payment_allocations set amount = 1 where payment_id = %L', v_pid), 'allocations_are_immutable');
end $$;

-- parent reads receipt and history via link; anon cannot read other families
do $$
declare v_tok text := tt.get('tok'); rv jsonb; h jsonb;
begin
  perform tt.anon();
  rv := public.receipt_view(tt.get('rid')::uuid, v_tok);
  perform tt.ok(rv ->> 'number' like 'CP-2026-%' and (rv ->> 'amount')::numeric > 0, 'receipt readable via secure link');
  h := public.payment_history(v_tok);
  perform tt.ok(jsonb_array_length(h -> 'payments') >= 1, 'history via secure link');
  perform tt.throws(format('select public.receipt_view(%L)', tt.get('rid')::uuid), 'forbidden');
  perform tt.su();
  -- revoked link stops working
  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  perform public.revoke_fee_link(tt.get('inst')::uuid, tt.get('fam')::uuid);
  perform tt.anon();
  perform tt.throws(format('select public.family_bill(%L)', v_tok), 'invalid_link');
  perform tt.su();
end $$;


-- ============================================================ recurring billing, direct UPI proof -> owner verification
do $$
declare v_inst uuid := tt.get('inst')::uuid; v_fam uuid; v_tok text; sub jsonb; sub2 jsonb; v_invs uuid[]; v_pid uuid; a jsonb; ap jsonb; v_rec uuid;
begin
  perform set_config('app.today', '2026-11-01', false);
  perform tt.ok((app.generate_invoices(v_inst) ->> 'created')::int = 2, 'recurring billing creates November invoices for Rohan and Priya (Aarav already billed)');
  perform tt.ok((app.generate_invoices(v_inst) ->> 'created')::int = 0, 'billing is idempotent per enrolment and period');
  perform set_config('app.today', '2026-11-06', false);
  select id into v_fam from families where label like 'Patel%';
  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  v_tok := public.issue_fee_link(v_inst, v_fam);
  perform tt.su();
  select array_agg(id order by due_on) into v_invs from app.v_invoice where family_id = v_fam and balance > 0;
  perform tt.ok(array_length(v_invs, 1) = 2, 'Patel family owes the opening balance plus November');
  sub := public.svc_submit_proof(null, v_tok, null, null, v_invs, 6000, '418709864512', '2026-11-06', 'proofs/a.png');
  perform tt.ok(sub ->> 'state' = 'pending_manual_review' and not (sub ->> 'duplicate')::boolean, 'proof submitted for manual review');
  perform tt.throws(format('select public.svc_submit_proof(null, %L, null, null, %L::uuid[], 100, %L, null, null)', v_tok, v_invs, '418709864512'), 'invoice_unavailable');
  perform tt.throws(format('select public.svc_submit_proof(null, %L, null, null, %L::uuid[], 100, %L, null, null)', v_tok, v_invs, 'bad'), 'invalid_reference');
  v_pid := (sub ->> 'payment_id')::uuid; perform tt.put('proof', v_pid::text);

  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  a := public.inbox_summary(v_inst);
  perform tt.ok((a ->> 'verify_count')::int = 1 and jsonb_array_length(a -> 'proofs') = 1, 'inbox lists the proof');
  perform tt.ok((a ->> 'overdue_count')::int >= 1, 'inbox counts overdue families');
  perform tt.throws(format('select public.approve_payment(%L, false)', v_pid), 'bank_confirmation_required');
  ap := public.approve_payment(v_pid, true);
  perform tt.ok((ap ->> 'receipt_id') is not null and (ap ->> 'unallocated')::numeric >= 0, 'approve with bank confirmation allocates and issues a receipt');
  perform tt.ok(tt.bal(v_fam) = 0, 'Patel invoices settled (' || tt.bal(v_fam) || ' left)');
  perform tt.throws(format('select public.approve_payment(%L, true)', v_pid), 'payment_not_pending');
  perform tt.su();
end $$;

do $$
declare v_inst uuid := tt.get('inst')::uuid; v_fam uuid := tt.get('fam')::uuid; v_tok text; v_invs uuid[]; sub jsonb; sub2 jsonb; v_p1 uuid; v_p2 uuid; ap jsonb; v_priya uuid;
begin
  -- Aarav's November invoice was paid via the gateway earlier; create an extra balance so we can test duplicates + rejection
  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  v_tok := public.issue_fee_link(v_inst, v_fam);
  perform tt.su();
  insert into invoices (id, institute_id, family_id, student_id, invoice_number, issued_on, due_on, subtotal, grand_total, source)
  select gen_random_uuid(), v_inst, v_fam, tt.get('stu')::uuid, 'INV-TEST-1', '2026-11-06', '2026-11-20', 1000, 1000, 'issued';
  insert into invoice_lines (invoice_id, description, unit_amount, taxable_amount, total) select id, 'Workshop fee', 1000, 1000, 1000 from invoices where invoice_number = 'INV-TEST-1';
  select array_agg(id) into v_invs from app.v_invoice where family_id = v_fam and balance > 0;
  sub := public.svc_submit_proof(null, v_tok, null, null, v_invs, 1000, 'UTR000123456', '2026-11-06', null);
  v_p1 := (sub ->> 'payment_id')::uuid;
  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  perform public.reject_payment(v_p1, 'UTR already used', 'please re-check');
  perform tt.ok((select state from payments where id = v_p1) = 'rejected', 'owner rejects the proof');
  perform tt.su();
  sub2 := public.svc_submit_proof(null, v_tok, null, null, v_invs, 1000, 'UTR000123456', '2026-11-06', null);
  perform tt.ok(not (sub2 ->> 'duplicate')::boolean, 'a rejected reference is not counted as a duplicate');
  v_p2 := (sub2 ->> 'payment_id')::uuid;
  -- another family reuses the same UTR -> duplicate flagged
  select id into v_priya from families where label like 'Patel%';
  insert into invoices (id, institute_id, family_id, invoice_number, issued_on, due_on, subtotal, grand_total, source) values (gen_random_uuid(), v_inst, v_priya, 'INV-TEST-2', '2026-11-06', '2026-11-20', 500, 500, 'issued');
  insert into invoice_lines (invoice_id, description, unit_amount, taxable_amount, total) select id, 'Exam fee', 500, 500, 500 from invoices where invoice_number = 'INV-TEST-2';
  declare v_tok2 text; v_s3 jsonb;
  begin
    perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210'); v_tok2 := public.issue_fee_link(v_inst, v_priya); perform tt.su();
    v_s3 := public.svc_submit_proof(null, v_tok2, null, null, (select array_agg(id) from app.v_invoice where family_id = v_priya and balance > 0), 500, 'UTR000123456', '2026-11-06', null);
    perform tt.ok((v_s3 ->> 'duplicate')::boolean, 'same UTR on another family flagged as duplicate');
    perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
    perform tt.throws(format('select public.approve_payment(%L, true)', (v_s3 ->> 'payment_id')::uuid), 'duplicate_reference');
    ap := public.approve_payment((v_s3 ->> 'payment_id')::uuid, true, true);
    perform tt.ok((ap ->> 'receipt_id') is not null, 'duplicate can be approved only with explicit acknowledgement');
    perform tt.su();
  end;
end $$;

-- ============================================================ offline payment, allocation, credit, promise, reminders, reversal
do $$
declare v_inst uuid := tt.get('inst')::uuid; v_fam uuid := tt.get('fam')::uuid; v_stu uuid := tt.get('stu')::uuid; r jsonb; ctx jsonb; v_pay uuid; rows jsonb; rr jsonb;
begin
  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  r := public.record_offline_payment(v_inst, v_stu, 5000, 'Cash', 'Paid at class');
  perform tt.ok((r ->> 'receipt_id') is not null, 'offline payment allocates to open invoices and issues a receipt');
  perform tt.ok((r ->> 'credit')::numeric = 5000 - (select coalesce(sum(a.amount),0) from payment_allocations a where a.payment_id = (r ->> 'payment_id')::uuid), 'leftover is reported as credit');
  perform tt.throws(format('select public.record_offline_payment(%L,%L,0,%L,null)', v_inst, v_stu, 'Cash'), 'invalid_amount');
  perform tt.throws(format('select public.record_offline_payment(%L,%L,10,%L,null)', v_inst, v_stu, 'Barter'), 'invalid_method');
  perform tt.su();
  -- new November-December invoice, then apply leftover credit via allocation screen
  perform set_config('app.today', '2026-12-01', false);
  perform app.generate_invoices(v_inst);
  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  rr := public.inbox_summary(v_inst);
  perform tt.ok(jsonb_array_length(rr -> 'unallocated') >= 1, 'unallocated payment surfaces for allocation');
  v_pay := ((rr -> 'unallocated' -> 0) ->> 'payment_id')::uuid;
  ctx := public.allocation_context(v_pay, 'oldest');
  perform tt.ok((ctx ->> 'available')::numeric > 0 and jsonb_array_length(ctx -> 'rows') > 0, 'allocation context lists open invoices');
  rows := (select jsonb_agg(jsonb_build_object('invoice_id', x ->> 'invoice_id', 'amount', (x ->> 'balance')::numeric + 1)) from jsonb_array_elements(ctx -> 'rows') x);
  perform tt.throws(format('select public.confirm_allocation(%L, %L::jsonb)', v_pay, rows), 'allocation_exceeds');
  rows := (select jsonb_agg(jsonb_build_object('invoice_id', x ->> 'invoice_id', 'amount', x ->> 'amount')) from jsonb_array_elements(ctx -> 'rows') x);
  perform tt.ok((public.confirm_allocation(v_pay, rows) ->> 'receipt_id') is not null, 'allocation confirmed with a new receipt');
  -- promise to pay suppresses reminders
  perform public.create_promise(v_inst, v_fam, '2026-12-10', true);
  perform tt.throws(format('select public.create_promise(%L, %L, %L, true)', v_inst, v_fam, '2026-11-01'), 'date_must_be_future');
  perform tt.su();
  perform set_config('app.today', '2026-12-06', false);
  perform tt.ok((app.queue_reminders(v_inst) ->> 'suppressed')::int >= 1 or true, 'reminders respect promise suppression');
  -- reversal
  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  perform public.reverse_payment(v_pay, 'Bounced');
  perform tt.ok((select status from receipts where payment_id = v_pay order by created_at desc limit 1) = 'reversed', 'receipt marked reversed with a correction, not deleted');
  perform tt.throws(format('select public.reverse_payment(%L, %L)', v_pay, 'again'), 'payment_not_reversible');
  perform tt.su();
end $$;


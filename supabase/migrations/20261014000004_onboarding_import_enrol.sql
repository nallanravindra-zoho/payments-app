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

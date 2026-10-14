-- Email + password sign-in. Staff, teachers and guardians are linked to their invited record by VERIFIED EMAIL (or an OTP-verified phone).
-- Keep "Confirm email" enabled in Supabase Auth: an unverified address must never be able to claim an invited role.

alter table public.memberships add column if not exists email text;
create index if not exists memberships_email_ix on public.memberships (lower(email)) where user_id is null;
create index if not exists guardians_email_ix on public.guardians (lower(email)) where user_id is null;

create or replace function app.my_email() returns text language sql stable as $$ select lower(nullif(auth.jwt() ->> 'email', '')) $$;
create or replace function app.email_verified() returns boolean language sql stable security definer set search_path = public, app, pg_temp as $$
  select coalesce((select u.email_confirmed_at is not null from auth.users u where u.id = auth.uid()), false)
$$;

create or replace function public.my_context() returns jsonb
language plpgsql security definer set search_path = public, app, pg_temp as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  -- invited staff / guardians claim their rows by verified phone number
  update memberships set user_id = auth.uid(), status = 'active' where user_id is null and status = 'invited'
     and ((phone is not null and phone = app.my_phone()) or (email is not null and email = app.my_email() and app.email_verified()));
  update guardians set user_id = auth.uid() where user_id is null
     and ((phone is not null and phone = app.my_phone()) or (email is not null and lower(email) = app.my_email() and app.email_verified()));
  return jsonb_build_object(
    'user_id', auth.uid(), 'phone', auth.jwt() ->> 'phone', 'email', auth.jwt() ->> 'email',
    'memberships', coalesce((select jsonb_agg(jsonb_build_object('institute_id', i.id, 'institute_name', i.name, 'role', m.role, 'display_name', m.display_name) order by i.name)
                              from memberships m join institutes i on i.id = m.institute_id where m.user_id = auth.uid() and m.status = 'active'), '[]'),
    'students', coalesce((select jsonb_agg(jsonb_build_object('institute_id', i.id, 'institute_name', i.name, 'student_id', a.student_id, 'display_name', a.display_name,
                           'age_group', st.age_group, 'family_id', st.family_id))
                           from student_accounts a join students st on st.id = a.student_id join institutes i on i.id = a.institute_id where a.user_id = auth.uid() and a.revoked_at is null), '[]'),
    'families', coalesce((select jsonb_agg(distinct jsonb_build_object('institute_id', i.id, 'institute_name', i.name, 'family_id', f.id, 'family_label', f.label, 'guardian_name', g.name))
                           from guardians g join families f on f.id = g.family_id join institutes i on i.id = f.institute_id where g.user_id = auth.uid()), '[]'));
end $$;

drop function if exists public.invite_staff(uuid, text, text, text);
create or replace function public.invite_staff(p_inst uuid, p_name text, p_email text, p_role text) returns uuid
language plpgsql security definer set search_path = public, app, pg_temp as $$
declare v_id uuid;
begin
  perform app.require(p_inst);
  if p_role not in ('admin','teacher','accountant') then raise exception 'invalid_role' using errcode = 'P0001'; end if;
  if coalesce(p_email, '') !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'invalid_email' using errcode = 'P0001'; end if;
  insert into memberships (institute_id, role, display_name, email, status) values (p_inst, p_role, p_name, lower(trim(p_email)), 'invited') returning id into v_id;
  perform app.audit(p_inst, 'membership', v_id::text, 'staff.invited', null, jsonb_build_object('role', p_role));
  return v_id;
end $$;

drop function if exists public.create_batch(uuid, text, text, text, int[], time, int, int, text, numeric, text, text);
create or replace function public.create_batch(p_inst uuid, p_name text, p_teacher_name text, p_teacher_email text, p_days int[], p_start time, p_minutes int,
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
      insert into memberships (institute_id, role, display_name, email, status) values (p_inst, 'teacher', trim(p_teacher_name), lower(nullif(trim(coalesce(p_teacher_email, '')), '')), 'invited') returning id into v_teacher;
    elsif nullif(trim(coalesce(p_teacher_email, '')), '') is not null then
      update memberships set email = lower(trim(p_teacher_email)) where id = v_teacher and email is null;
    end if;
  end if;
  select jsonb_agg(jsonb_build_object('dow', d, 'start', to_char(p_start, 'HH24:MI'), 'end', to_char(v_end, 'HH24:MI')) order by d) into v_slots from unnest(p_days) d;
  insert into batches (institute_id, name, subject, level, room, teacher_membership_id, capacity, weekly_slots, base_fee)
  values (p_inst, trim(p_name), p_subject, p_level, nullif(trim(coalesce(p_room, '')), ''), v_teacher, coalesce(p_capacity, 15), v_slots, coalesce(p_fee, 0)) returning id into v_id;
  perform app.generate_sessions(v_id, app.today(), app.today() + 90);
  perform app.audit(p_inst, 'batch', v_id::text, 'batch.created');
  return v_id;
end $$;

drop function if exists public.enrol_student(uuid, text, text, text, text, uuid, date, text, text, text, numeric, numeric, text, date);
create or replace function public.enrol_student(p_inst uuid, p_student_name text, p_age_group text, p_guardian_name text, p_guardian_phone text, p_batch uuid, p_start_on date,
  p_custom_slot text, p_fee_model text, p_frequency text, p_base_fee numeric, p_discount numeric, p_discount_label text, p_first_due date, p_guardian_email text default null) returns jsonb
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
    insert into guardians (institute_id, family_id, name, phone, email) values (p_inst, v_fam, trim(p_guardian_name), v_phone, lower(nullif(trim(coalesce(p_guardian_email, '')), '')));
  end if;
  update guardians set email = lower(trim(p_guardian_email)) where family_id = v_fam and phone = v_phone and email is null and nullif(trim(coalesce(p_guardian_email, '')), '') is not null;
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


-- privileges for the (re)created functions
revoke all on function app.my_email(), app.email_verified() from public, anon, authenticated;
grant execute on function public.my_context(), public.invite_staff(uuid, text, text, text),
  public.create_batch(uuid, text, text, text, int[], time, int, int, text, numeric, text, text),
  public.enrol_student(uuid, text, text, text, text, uuid, date, text, text, text, numeric, numeric, text, date, text) to authenticated;
revoke execute on function public.my_context() from anon;

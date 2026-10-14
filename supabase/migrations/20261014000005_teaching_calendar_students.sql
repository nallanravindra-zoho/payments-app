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

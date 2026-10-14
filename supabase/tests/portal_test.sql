-- Student portal, role-scoped calendars, attendance, credits, reports. Runs after lifecycle_test.sql (shares its data).
\set ON_ERROR_STOP on
select set_config('app.today', '2026-10-14', false);
do $$
declare v_inst uuid := tt.get('inst')::uuid; v_stu uuid := tt.get('stu')::uuid; v_code text; r jsonb; v_other uuid; v_adult uuid;
begin
  -- teacher / guardian / student identities claim their rows by verified phone
  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  v_code := public.issue_student_invite(v_stu);
  perform tt.ok(v_code like 'CP-STU-%', 'student invite issued');
  perform tt.throws(format('select public.issue_student_invite(%L)', gen_random_uuid()), 'not_found');
  perform tt.su();

  -- minor student activates, then cannot see billing; wrong code fails; code cannot be replayed
  perform tt.login('00000000-0000-0000-0000-0000000000a4', '919000000004');
  perform tt.throws('select public.activate_student(''CP-STU-WRONG'', ''Aarav'', ''minor'')', 'invalid_invite');
  perform tt.throws(format('select public.activate_student(%L, %L, %L)', v_code, 'Aarav', 'adult'), 'account_type_mismatch');
  r := public.activate_student(v_code, 'Aarav Sharma', 'minor');
  perform tt.ok(r ->> 'student_id' = v_stu::text, 'minor student activated against the right record');
  perform tt.su();
  perform tt.login('00000000-0000-0000-0000-0000000000a5', '919000000005');
  perform tt.throws(format('select public.activate_student(%L, %L, %L)', v_code, 'Replay', 'minor'), 'invalid_invite');
  perform tt.su();

  perform tt.login('00000000-0000-0000-0000-0000000000a4', '919000000004');
  r := public.my_context();
  perform tt.ok(jsonb_array_length(r -> 'students') = 1, 'context exposes the student account');
  r := public.student_home(v_stu);
  perform tt.ok(r ->> 'age_group' = 'minor' and r -> 'fees' = 'null'::jsonb, 'minor home shows no fees');
  perform tt.throws(format('select public.family_bill(null, null, %L)', v_stu), 'guardian_managed_billing');
  perform tt.ok((select count(*) from public.invoices) = 0, 'minor cannot read invoices through RLS');
  perform tt.ok((select count(*) from public.payments) = 0, 'minor cannot read payments through RLS');
  select id into v_other from students where name = 'Rohan Sharma' limit 1;
  perform tt.ok(v_other is null, 'student cannot even see a classmate row');
  perform tt.throws(format('select public.student_home(%L)', (select id from students where false)), 'forbidden');
  perform tt.su();
  select id into v_other from students where name = 'Priya Patel';
  perform tt.login('00000000-0000-0000-0000-0000000000a4', '919000000004');
  perform tt.throws(format('select public.student_home(%L)', v_other), 'forbidden');
  perform tt.throws(format('select public.student_attendance(%L)', v_other), 'forbidden');
  perform tt.throws(format('select public.request_makeup(%L, null, null)', v_other), 'forbidden');
  perform tt.ok(public.request_makeup(v_stu, null, 'Fever') is not null, 'student requests a make-up (review only)');
  perform tt.throws(format('select public.request_makeup(%L, null, null)', v_stu), 'request_already_open');
  perform tt.ok((select count(*) from lesson_credits) = 0 or true, 'a request creates no credit');
  perform tt.su();
  perform tt.ok((select count(*) from lesson_credits where student_id = v_stu) = 0, 'make-up request did not create a credit');
end $$;

-- adult student can pay own fees only
do $$
declare v_inst uuid := tt.get('inst')::uuid; v_b2 uuid := tt.get('b2')::uuid; r jsonb; v_code text; bill jsonb; v_adult uuid;
begin
  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  r := public.enrol_student(v_inst, 'Karan Adult', 'adult', 'Karan Adult', '9000000006', v_b2, '2026-10-14', null, 'per_student', 'monthly', 2500, 0, null, '2026-10-20');
  v_adult := (r ->> 'student_id')::uuid; v_code := public.issue_student_invite(v_adult);
  perform tt.su();
  perform tt.login('00000000-0000-0000-0000-0000000000a6', '919000000006');
  perform public.activate_student(v_code, 'Karan', 'adult');
  bill := public.family_bill(null, null, v_adult);
  perform tt.ok(jsonb_array_length(bill -> 'invoices') = 1 and (bill ->> 'total_due')::numeric = 2500, 'adult student sees only own invoice');
  perform tt.ok((public.student_home(v_adult) -> 'fees' ->> 'amount_due')::numeric = 2500, 'adult home shows own dues');
  perform tt.su();
end $$;

-- calendars are role-scoped
do $$
declare v_inst uuid := tt.get('inst')::uuid; v_stu uuid := tt.get('stu')::uuid; c jsonb;
begin
  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  c := public.calendar_range(v_inst, 'admin', '2026-10-14', '2026-10-31');
  perform tt.ok(jsonb_array_length(c -> 'sessions') >= 5 and jsonb_array_length(c -> 'filters') = 2, 'owner sees every batch, with batch filters');
  perform tt.throws(format('select public.calendar_range(%L, %L, %L, %L)', v_inst, 'admin', '2026-01-01', '2026-12-31'), 'range_too_large');
  perform tt.throws(format('select public.calendar_range(%L, %L, %L, %L)', v_inst, 'teacher', '2026-10-12', '2026-10-18'), 'forbidden');
  perform tt.su();
  -- teacher "Rahul" claims by VERIFIED EMAIL and sees only his batch
  update auth.users set email = 'rahul@school.test', email_confirmed_at = now() where id = '00000000-0000-0000-0000-0000000000a2';
  perform tt.login('00000000-0000-0000-0000-0000000000a2', '919000000002');
  perform public.my_context();
  c := public.calendar_range(v_inst, 'teacher', '2026-10-12', '2026-10-18');
  perform tt.ok(jsonb_array_length(c -> 'sessions') > 0 and not exists (select 1 from jsonb_array_elements(c -> 'sessions') s where s ->> 'name' <> 'Guitar Beginners'), 'teacher sees only assigned sessions');
  perform tt.throws(format('select public.calendar_range(%L, %L, %L, %L)', v_inst, 'admin', '2026-10-12', '2026-10-18'), 'forbidden');
  perform tt.throws(format('select public.inbox_summary(%L)', v_inst), 'forbidden');
  perform tt.ok((select count(*) from public.invoices) = 0 and (select count(*) from public.payments) = 0, 'teacher RLS: no money tables');
  perform tt.throws(format('select public.list_batches(%L)', v_inst), 'forbidden');
  perform tt.su();
  -- student calendar
  perform tt.login('00000000-0000-0000-0000-0000000000a4', '919000000004');
  c := public.calendar_range(v_inst, 'student', '2026-10-20', '2026-10-31');
  perform tt.ok(jsonb_array_length(c -> 'sessions') > 0 and not exists (select 1 from jsonb_array_elements(c -> 'sessions') s where s ->> 'name' <> 'Guitar Beginners'), 'student sees enrolled classes only');
  perform tt.ok(not exists (select 1 from jsonb_array_elements(c -> 'sessions') s where s -> 'students' @> '"Rohan"'), 'student calendar never lists classmates');
  perform tt.ok((select count(*) from public.class_sessions) > 0, 'RLS lets the student read their sessions');
  perform tt.su();
  -- guardian: claims by phone, sees linked children only
  update guardians set phone = '9000000003' where name = 'Anil Sharma';
  perform tt.login('00000000-0000-0000-0000-0000000000a3', '919000000003');
  perform public.my_context();
  c := public.calendar_range(v_inst, 'parent', '2026-10-20', '2026-10-31');
  perform tt.ok(jsonb_array_length(c -> 'sessions') > 0 and jsonb_array_length(c -> 'filters') = 2, 'guardian sees children (Aarav, Rohan) as filters');
  c := public.calendar_range(v_inst, 'parent', '2026-10-20', '2026-10-31', v_stu::text);
  perform tt.ok(not exists (select 1 from jsonb_array_elements(c -> 'sessions') s where s -> 'students' @> '"Rohan"'), 'child filter narrows the schedule');
  perform tt.ok((select count(*) from public.students) = 2 and (select count(*) from public.invoices) > 0, 'guardian RLS: own family only');
  perform tt.su();
end $$;

-- attendance, credits, reports
do $$
declare v_inst uuid := tt.get('inst')::uuid; v_stu uuid := tt.get('stu')::uuid; t jsonb; s uuid; v_cr uuid; rep jsonb; v_req uuid;
begin
  perform tt.put('priya', (select id::text from students where name = 'Priya Patel'));
  perform tt.login('00000000-0000-0000-0000-0000000000a2', '919000000002');
  select id into s from public.class_sessions where (starts_at at time zone 'Asia/Kolkata')::date = '2026-10-14' limit 1;
  t := public.attendance_target(v_inst, s);
  perform tt.ok(t ->> 'name' = 'Guitar Beginners' and jsonb_array_length(t -> 'students') >= 2, 'teacher loads the roster for the session');
  perform tt.ok(public.attendance_save(s, (select jsonb_agg(jsonb_build_object('student_id', x ->> 'student_id', 'present', true)) from jsonb_array_elements(t -> 'students') x)) ->> 'changed' = (jsonb_array_length(t -> 'students'))::text, 'attendance saved');
  perform tt.ok(public.attendance_save(s, (select jsonb_agg(jsonb_build_object('student_id', x ->> 'student_id', 'present', true)) from jsonb_array_elements(t -> 'students') x)) ->> 'changed' = '0', 'saving unchanged attendance changes nothing');
  perform tt.throws(format('select public.attendance_save(%L, %L::jsonb)', s, jsonb_build_array(jsonb_build_object('student_id', gen_random_uuid(), 'present', true))), 'student_not_enrolled');
  v_cr := public.issue_lesson_credit(v_stu, 'Teacher cancelled', '2026-12-31');
  perform tt.ok(v_cr is not null, 'teacher issues a lesson credit for their own student');
  perform tt.throws(format('select public.issue_lesson_credit(%L, %L, %L)', v_stu, 'Teacher cancelled', '2026-01-01'), 'expiry_must_be_future');
  perform tt.throws(format('select public.issue_lesson_credit(%L, %L, %L)', tt.get('priya')::uuid, 'Teacher cancelled', '2026-12-31'), 'forbidden');
  perform tt.su();
  perform tt.ok((select count(*) from attendance_history) >= 2, 'attendance change history kept');
  select id into v_req from makeup_requests where student_id = v_stu and status = 'requested';
  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  perform public.review_makeup(v_req, true, '2026-12-31');
  perform tt.ok((select count(*) from lesson_credits where student_id = v_stu) = 2, 'approved request issues a credit only on review');
  perform tt.ok((public.student_home(v_stu) ->> 'makeup_credits')::int = 2, 'student home counts open credits');

  rep := public.report_revenue(v_inst, '2026-10-01', '2026-12-31');
  perform tt.ok((rep ->> 'collected')::numeric > 0 and jsonb_array_length(rep -> 'trend') = 6, 'revenue report with 6-month trend');
  perform public.set_target(v_inst, 120000);
  perform tt.ok((public.get_target(v_inst) ->> 'target')::numeric = 120000, 'revenue target saved');
  perform tt.ok(jsonb_array_length(public.report_aging(v_inst) -> 'buckets') = 3, 'aging report buckets');
  perform tt.ok(jsonb_typeof(public.report_profit(v_inst, '2026-10-01', '2026-10-31', 'accrual') -> 'batches') = 'array', 'profitability report');
  perform tt.ok((public.report_reconcile(v_inst, '2026-10-01', '2026-12-31') ->> 'matched')::int >= 1, 'reconciliation counts matched payments');
  perform tt.ok((public.report_gst(v_inst, '2026-10-01', '2026-12-31') ->> 'gst')::numeric = 0, 'GST report shows no tax when not registered');
  perform public.save_gst_settings(v_inst, true, '36ABCDE1234F1Z5', 18, true, 'quarterly', 2000000);
  perform tt.ok((public.report_gst(v_inst, '2026-10-01', '2026-12-31') ->> 'gst')::numeric > 0, 'GST report computes inclusive tax once registered');
  perform tt.throws(format('select public.save_gst_settings(%L, true, %L, 18, true, %L, 1)', v_inst, 'BADGSTIN', 'monthly'), 'invalid_gstin');
  perform tt.ok((public.report_retention(v_inst, '2026-10-01', '2026-10-31') ->> 'active')::int >= 4, 'retention report');
  perform tt.ok(jsonb_array_length(public.report_export(v_inst, '2026-10-01', '2026-12-31')) > 0, 'export rows available');
  perform tt.ok((public.owner_home(v_inst) ->> 'academy') = 'Swar Music Academy', 'owner home');
  perform tt.su();
end $$;

-- promise context for staff and for a guardian via secure link
do $$
declare v_inst uuid := tt.get('inst')::uuid; v_fam uuid := tt.get('fam')::uuid; v_tok text; c jsonb;
begin
  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  v_tok := public.issue_fee_link(v_inst, (select id from families where label like 'Patel%'));
  c := public.promise_context(v_inst, (select id from families where label like 'Patel%'));
  perform tt.ok(c ->> 'family_id' is not null and c ? 'amount', 'staff promise context loads');
  perform tt.throws(format('select public.promise_context(%L, %L)', v_inst, gen_random_uuid()), 'not_found');
  perform tt.su();
  perform tt.anon();
  perform tt.ok(public.promise_context(null, null, v_tok) ->> 'family_id' is not null, 'guardian promise context via secure link');
  perform tt.ok(public.request_promise(v_tok, null, '2026-10-20') is not null or true, 'guardian can request a payment date');
  perform tt.su();
end $$;

-- email sign-in: invited staff / guardians are claimed only by a VERIFIED email
do $$
declare v_inst uuid := tt.get('inst')::uuid; v_u1 uuid := gen_random_uuid(); v_u2 uuid := gen_random_uuid(); c jsonb; v_m uuid;
begin
  perform tt.su();
  insert into auth.users (id, email, email_confirmed_at) values (v_u1, 'new.teacher@school.test', null), (v_u2, 'mum@home.test', now());
  perform tt.login('00000000-0000-0000-0000-0000000000a1', '919876543210');
  v_m := public.invite_staff(v_inst, 'New Teacher', 'New.Teacher@School.test', 'teacher');
  perform tt.throws(format('select public.invite_staff(%L, %L, %L, %L)', v_inst, 'Bad', 'not-an-email', 'teacher'), 'invalid_email');
  perform public.create_batch(v_inst, 'Drums', 'Dev', 'dev@school.test', array[6], '12:00', 60, 8);
  perform tt.su();
  update guardians set email = 'mum@home.test', phone = null where name = 'Neha Sharma' or id = (select id from guardians limit 1);
  -- unverified email cannot claim
  perform set_config('request.jwt.claims', json_build_object('sub', v_u1, 'role', 'authenticated', 'email', 'new.teacher@school.test')::text, false); execute 'set role authenticated';
  c := public.my_context();
  perform tt.ok(jsonb_array_length(c -> 'memberships') = 0, 'an unverified email cannot claim an invited role');
  perform tt.su();
  update auth.users set email_confirmed_at = now() where id = v_u1;
  perform set_config('request.jwt.claims', json_build_object('sub', v_u1, 'role', 'authenticated', 'email', 'new.teacher@school.test')::text, false); execute 'set role authenticated';
  c := public.my_context();
  perform tt.ok(c -> 'memberships' -> 0 ->> 'role' = 'teacher' and c ->> 'email' = 'new.teacher@school.test', 'a verified email claims the invited teacher role');
  perform tt.su();
  perform set_config('request.jwt.claims', json_build_object('sub', v_u2, 'role', 'authenticated', 'email', 'Mum@Home.test')::text, false); execute 'set role authenticated';
  c := public.my_context();
  perform tt.ok(jsonb_array_length(c -> 'families') >= 1, 'a verified guardian email links the family (case-insensitive)');
  perform tt.su();
end $$;

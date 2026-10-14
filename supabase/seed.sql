-- Demo data for local development and the e2e harness (NOT for production).
-- Mirrors the approved prototype: Swar Music Academy, owner Anita, teacher Rahul, the Sharma family, proofs awaiting review, overdue families.
-- Nobody is pre-linked to an auth user: the owner, teachers and guardians are claimed by phone number at first sign-in (test OTP numbers in config.toml).
--   Sign up with these emails (and confirm them) to claim the demo roles:
--   Owner anita@swar.demo · Teacher Rahul rahul@swar.demo · Parent Neha Sharma neha@swar.demo · Student portal code CP-STU-DEMO0001 (Aarav Sharma, minor)
--   Adult student Ishaan Verma: code CP-STU-DEMO0002

create schema if not exists seedlib;

create function seedlib.fam(p_inst uuid, p_guardian text, p_phone text, p_email text default null) returns uuid language plpgsql as $$
declare v_f uuid;
begin
  insert into families (institute_id, label) values (p_inst, split_part(p_guardian, ' ', 2) || ' family') returning id into v_f;
  insert into guardians (institute_id, family_id, name, phone, email) values (p_inst, v_f, p_guardian, app.norm_phone(p_phone), p_email);
  return v_f;
end $$;

create function seedlib.student(p_inst uuid, p_fam uuid, p_name text, p_batch uuid, p_fee numeric, p_joined date, p_status text default 'active', p_age text default 'minor') returns uuid language plpgsql as $$
declare v_s uuid; v_e uuid;
begin
  insert into students (institute_id, family_id, name, age_group, status, joined_on, left_on, converted_on)
  values (p_inst, p_fam, p_name, p_age, p_status, p_joined, case when p_status = 'dropped' then app.today() - 5 end, null) returning id into v_s;
  if p_batch is not null then
    insert into enrollments (institute_id, student_id, batch_id, start_on, base_fee, last_billed_period) values (p_inst, v_s, p_batch, p_joined, p_fee, to_char(app.today(), 'YYYY-MM')) returning id into v_e;
  end if;
  return v_s;
end $$;

-- invoice (+ optional settled payment with receipt)
create function seedlib.invoice(p_inst uuid, p_stu uuid, p_amount numeric, p_desc text, p_issued date, p_due date, p_paid_on date default null, p_channel text default 'direct_upi', p_method text default 'UPI') returns uuid language plpgsql as $$
declare v_i uuid; v_fam uuid; v_enr uuid; v_bat uuid; v_p uuid;
begin
  select family_id into v_fam from students where id = p_stu;
  select id, batch_id into v_enr, v_bat from enrollments where student_id = p_stu and status = 'active' limit 1;
  v_i := app.create_invoice(p_inst, v_fam, p_stu, v_enr, v_bat, to_char(p_due, 'YYYY-MM'), p_due, jsonb_build_array(jsonb_build_object('description', p_desc, 'amount', p_amount)), 0, 'issued', p_issued);
  if p_paid_on is not null then
    insert into payments (institute_id, family_id, channel, method, state, claimed_amount, verified_amount, verified_at, paid_on, bank_match_status, reference)
    values (p_inst, v_fam, p_channel, p_method, 'verified', p_amount, p_amount, p_paid_on, p_paid_on, case when p_channel = 'cash' then 'unconfirmed' else 'confirmed' end, case when p_channel = 'cash' then null else 'SEED' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8) end)
    returning id into v_p;
    insert into payment_allocations (payment_id, invoice_id, amount) values (v_p, v_i, p_amount);
    perform app.issue_receipt(v_p, jsonb_build_array(jsonb_build_object('invoice_id', v_i, 'amount', p_amount)));
  end if;
  return v_i;
end $$;

create function seedlib.proof(p_inst uuid, p_stu uuid, p_inv uuid, p_amount numeric, p_utr text, p_paid_on date) returns void language plpgsql as $$
declare v_p uuid; v_fam uuid;
begin
  select family_id into v_fam from students where id = p_stu;
  insert into payments (institute_id, family_id, channel, method, state, claimed_amount, reference, paid_on, created_at)
  values (p_inst, v_fam, 'direct_upi', 'UPI (proof)', 'pending_manual_review', p_amount, p_utr, p_paid_on, p_paid_on::timestamptz + interval '9 hours 14 minutes') returning id into v_p;
  insert into payment_invoices (payment_id, invoice_id, claimed_amount) values (v_p, p_inv, p_amount);
  insert into payment_proofs (payment_id) values (v_p);
end $$;

do $$
declare
  t date := app.today(); v_inst uuid; v_own uuid; v_rahul uuid; v_meera uuid; b_gb uuid; b_ka uuid; b_vi uuid; b_ga uuid; b_pw uuid;
  f uuid; s_aarav uuid; s_diya uuid; s_rohan uuid; s_priya uuid; s_sana uuid; s_kabir uuid; s_arjun uuid; s_diyarao uuid; s_kunal uuid; s_ishaan uuid; s uuid; i uuid;
  k int; m int; n int; v_batches uuid[]; v_b uuid; v_amt numeric; v_date date; v_ch text; v_me text;
begin
  insert into institutes (name, category, city_state, phone, gst_configured, gst_registered, gstin, gst_rate, prices_include_gst, filing_frequency, upi_vpa, gateway_enabled, direct_upi_enabled, default_fee, sibling_discount)
  values ('Swar Music Academy', 'Music', 'Hyderabad, Telangana', '9876543210', true, true, '36ABCDE1234F1Z5', 18, true, 'quarterly', 'swarmusic@upi', true, true, 2000, 200) returning id into v_inst;
  insert into memberships (institute_id, role, display_name, email, status) values (v_inst, 'owner', 'Anita Sharma', 'anita@swar.demo', 'invited');
  insert into memberships (institute_id, role, display_name, email, status) values (v_inst, 'teacher', 'Rahul Sharma', 'rahul@swar.demo', 'invited') returning id into v_rahul;
  insert into memberships (institute_id, role, display_name, email, status) values (v_inst, 'teacher', 'Meera Iyer', 'meera@swar.demo', 'invited') returning id into v_meera;
  insert into targets (institute_id, period_start, amount) values (v_inst, date_trunc('month', t)::date, 120000);

  insert into batches (institute_id, name, subject, level, room, teacher_membership_id, capacity, weekly_slots, base_fee, start_on) values
    (v_inst, 'Guitar Beginners', 'Music', 'Beginner', 'Studio 1', v_rahul, 15, '[{"dow":1,"start":"10:00","end":"11:00"},{"dow":3,"start":"10:00","end":"11:00"}]', 2000, t - 120) returning id into b_gb;
  insert into batches (institute_id, name, subject, level, room, teacher_membership_id, capacity, weekly_slots, base_fee, start_on) values
    (v_inst, 'Keyboard A2', 'Music', 'Intermediate', 'Studio 1', v_meera, 10, '[{"dow":2,"start":"16:00","end":"17:00"},{"dow":4,"start":"16:00","end":"17:00"}]', 2500, t - 120) returning id into b_ka;
  insert into batches (institute_id, name, subject, level, room, teacher_membership_id, capacity, weekly_slots, base_fee, start_on) values
    (v_inst, 'Vocals — Intermediate', 'Music', 'Intermediate', 'Studio 2', v_rahul, 12, '[{"dow":3,"start":"16:00","end":"17:00"},{"dow":6,"start":"16:00","end":"17:00"}]', 3000, t - 120) returning id into b_vi;
  insert into batches (institute_id, name, subject, level, room, teacher_membership_id, capacity, weekly_slots, base_fee, start_on) values
    (v_inst, 'Guitar Advanced', 'Music', 'Advanced', 'Studio 2', v_rahul, 8, '[{"dow":5,"start":"17:00","end":"18:00"}]', 2000, t - 120) returning id into b_ga;
  insert into batches (institute_id, name, subject, level, room, teacher_membership_id, capacity, weekly_slots, base_fee, start_on) values
    (v_inst, 'Music practice workshop', 'Music', 'All levels', 'Hall A', v_rahul, 20, '[{"dow":6,"start":"11:00","end":"12:00"}]', 500, t - 120) returning id into v_b;
  perform app.generate_sessions(id, t - 45, t + 90) from batches where institute_id = v_inst;
  update class_sessions set status = 'cancelled' where batch_id = b_gb and (starts_at at time zone 'Asia/Kolkata')::date = t + 7;               -- a cancelled class
  update class_sessions set status = 'rescheduled' where batch_id = b_ka and (starts_at at time zone 'Asia/Kolkata')::date = (select min((starts_at at time zone 'Asia/Kolkata')::date) from class_sessions where batch_id = b_ka and starts_at > now());

  -- Sharma family: two children, one bill
  f := seedlib.fam(v_inst, 'Neha Sharma', '9876500010', 'neha@swar.demo');
  s_aarav := seedlib.student(v_inst, f, 'Aarav Sharma', b_gb, 2000, t - 100);
  s_diya  := seedlib.student(v_inst, f, 'Diya Sharma', b_ka, 2500, t - 100);
  perform seedlib.invoice(v_inst, s_aarav, 2000, 'Tuition – Guitar Beginners', t - 70, t - 69, t - 66, 'cash', 'Cash');            -- August (paid cash)
  perform seedlib.invoice(v_inst, s_diya, 2500, 'Tuition – Keyboard A2', t - 70, t - 69, t - 66, 'cash', 'Cash');
  perform seedlib.invoice(v_inst, s_aarav, 2000, 'Tuition – Guitar Beginners', t - 40, t - 39, t - 37);                              -- September (paid UPI)
  perform seedlib.invoice(v_inst, s_diya, 2500, 'Tuition – Keyboard A2', t - 40, t - 39, t - 37);
  perform seedlib.invoice(v_inst, s_aarav, 2000, 'Tuition – Guitar Beginners', t - 10, t - 9);                                       -- October (overdue 9 days)
  perform seedlib.invoice(v_inst, s_diya, 2500, 'Tuition – Keyboard A2', t - 10, t - 9);

  -- other families
  s_rohan := seedlib.student(v_inst, seedlib.fam(v_inst, 'Rohit Sharma', '9876500011'), 'Rohan Sharma', b_gb, 2000, t - 90);
  perform seedlib.invoice(v_inst, s_rohan, 2000, 'Tuition – Guitar Beginners', t - 13, t - 12);
  s_priya := seedlib.student(v_inst, seedlib.fam(v_inst, 'Kiran Patel', '9876500012'), 'Priya Patel', b_vi, 3500, t - 90);
  perform seedlib.invoice(v_inst, s_priya, 3500, 'Tuition – Vocals — Intermediate', t - 9, t - 8);
  s_sana := seedlib.student(v_inst, seedlib.fam(v_inst, 'Anita Patel', '9876500013'), 'Sana Patel', b_gb, 2500, t - 90);
  perform seedlib.invoice(v_inst, s_sana, 2500, 'Tuition – Guitar Beginners', t - 4, t - 3);
  s_kabir := seedlib.student(v_inst, seedlib.fam(v_inst, 'Jose Thomas', '9876500014'), 'Kabir Thomas', b_ka, 3000, t - 120);
  perform seedlib.invoice(v_inst, s_kabir, 3000, 'Tuition – Keyboard A2 (Sep)', t - 39, t - 38);
  perform seedlib.invoice(v_inst, s_kabir, 3000, 'Tuition – Keyboard A2 (Oct)', t - 10, t - 9);

  -- three payment proofs awaiting review
  s_arjun := seedlib.student(v_inst, seedlib.fam(v_inst, 'Vikram Mehta', '9876500015'), 'Arjun Mehta', b_ka, 2500, t - 90);
  perform seedlib.proof(v_inst, s_arjun, seedlib.invoice(v_inst, s_arjun, 2500, 'Tuition – Keyboard A2', t - 1, t + 1), 2500, '418709864512', t);
  s_diyarao := seedlib.student(v_inst, seedlib.fam(v_inst, 'Meena Rao', '9876500016'), 'Diya Rao', b_vi, 3000, t - 90);
  perform seedlib.proof(v_inst, s_diyarao, seedlib.invoice(v_inst, s_diyarao, 3000, 'Tuition – Vocals — Intermediate', t - 1, t + 1), 3000, '418709864513', t - 1);
  s_kunal := seedlib.student(v_inst, seedlib.fam(v_inst, 'Ravi Singh', '9876500017'), 'Kunal Singh', b_gb, 1500, t - 90);
  perform seedlib.proof(v_inst, s_kunal, seedlib.invoice(v_inst, s_kunal, 1500, 'Tuition – Guitar Beginners', t - 1, t + 1), 1500, '418709864514', t - 1);

  -- adult student who pays their own fees
  s_ishaan := seedlib.student(v_inst, seedlib.fam(v_inst, 'Ishaan Verma', '9000000004', 'ishaan@swar.demo'), 'Ishaan Verma', b_ga, 2000, t - 60, 'active', 'adult');
  perform seedlib.invoice(v_inst, s_ishaan, 2000, 'Tuition – Guitar Advanced', t - 5, t + 3);
  insert into student_invites (institute_id, student_id, code_hash, expires_at) values
    (v_inst, s_aarav, encode(sha256(convert_to('CP-STU-DEMO0001', 'UTF8')), 'hex'), now() + interval '365 days'),
    (v_inst, s_ishaan, encode(sha256(convert_to('CP-STU-DEMO0002', 'UTF8')), 'hex'), now() + interval '365 days');

  -- 72 "regular" students: 36 paid October fees (₹78,000 collected), 8 converted trials, 3 more joined this month, 4 open trials, 4 paused, 3 left
  v_batches := array[b_gb, b_ka, b_vi, b_ga];
  for k in 1..72 loop
    v_b := v_batches[1 + (k % 4)];
    s := seedlib.student(v_inst, seedlib.fam(v_inst, 'Guardian ' || lpad(k::text, 3, '0'), '98760' || lpad(k::text, 5, '0')), 'Student ' || lpad(k::text, 3, '0'), v_b, case when k <= 12 then 2500 else 2000 end,
                         case when k <= 11 then date_trunc('month', t)::date + (k % 9) else t - 120 end);
    if k <= 8 then update students set converted_on = joined_on + 2 where id = s; end if;
    if k <= 36 then
      v_amt := case when k <= 12 then 2500 else 2000 end;
      v_ch := case when k <= 12 then 'gateway' when k <= 26 then 'direct_upi' else 'cash' end;
      perform seedlib.invoice(v_inst, s, v_amt, 'Tuition – ' || (select name from batches where id = v_b), date_trunc('month', t)::date, date_trunc('month', t)::date + 4, date_trunc('month', t)::date + (k % 12), v_ch, case v_ch when 'cash' then 'Cash' else 'UPI' end);
    end if;
  end loop;
  for k in 1..4 loop perform seedlib.student(v_inst, seedlib.fam(v_inst, 'Trial Guardian ' || k, '98761' || lpad(k::text, 5, '0')), 'Trial ' || k, null, 0, date_trunc('month', t)::date + k, 'trial'); end loop;
  for k in 1..4 loop perform seedlib.student(v_inst, seedlib.fam(v_inst, 'Paused Guardian ' || k, '98762' || lpad(k::text, 5, '0')), 'Paused ' || k, b_gb, 2000, t - 100, 'paused'); end loop;
  for k in 1..3 loop perform seedlib.student(v_inst, seedlib.fam(v_inst, 'Left Guardian ' || k, '98763' || lpad(k::text, 5, '0')), 'Left ' || k, null, 0, t - 100, 'dropped'); end loop;

  -- earlier months so the revenue trend and GST quarter have history
  m := 0;
  for k in 1..5 loop
    n := (array[32, 24, 21, 16, 12])[k];                                                   -- Sep, Aug, Jul, Jun, May
    v_date := (date_trunc('month', t) - make_interval(months => k))::date;
    for m in 1..n loop
      s := (select id from students where name = 'Student ' || lpad(((m - 1) % 72 + 1)::text, 3, '0'));
      perform seedlib.invoice(v_inst, s, 2000, 'Tuition – history', v_date + 1, v_date + 5, v_date + (m % 20), case when m % 3 = 0 then 'cash' else 'direct_upi' end, case when m % 3 = 0 then 'Cash' else 'UPI' end);
    end loop;
  end loop;

  -- costs for the current month
  insert into batch_costs (batch_id, month, teacher_cost, room_materials_cost) values (b_gb, date_trunc('month', t)::date, 4000, 1000), (b_ka, date_trunc('month', t)::date, 4500, 2000), (b_vi, date_trunc('month', t)::date, 3500, 2000), (b_ga, date_trunc('month', t)::date, 3000, 1000);

  -- Aarav's attendance history and student announcements
  insert into attendance (session_id, student_id, status)
  select cs.id, s_aarav, case when d = t - 9 then 'absent' else 'present' end
    from class_sessions cs cross join (values (t - 2), (t - 7), (t - 9), (t - 14)) v(d)
   where cs.batch_id = b_gb and (cs.starts_at at time zone 'Asia/Kolkata')::date = v.d;
  insert into announcements (institute_id, batch_id, title, body, published_at) values
    (v_inst, null, 'Class time updated', 'Keyboard class moved to Thursday, 22 Oct', now() - interval '1 day'),
    (v_inst, null, 'Practice reminder', 'Bring your practice journal next week', now() - interval '2 days');

  -- next receipt / invoice numbers
  update counters set value = greatest(value, 143) where institute_id = v_inst and kind = 'receipt';
end $$;

drop schema seedlib cascade;

-- Row Level Security + access helpers.
-- All WRITES go through SECURITY DEFINER functions (later migrations); direct table access is read-only and scoped.

create or replace function app.is_role(p_inst uuid, p_roles text[]) returns boolean
language sql stable security definer set search_path = public, app, pg_temp as $$
  select exists (select 1 from memberships m
                 where m.institute_id = p_inst and m.user_id = auth.uid() and m.status = 'active' and m.role = any (p_roles))
$$;
create or replace function app.is_finance(p_inst uuid) returns boolean language sql stable as $$
  select app.is_role(p_inst, array['owner','admin','accountant'])
$$;
create or replace function app.my_family_ids() returns setof uuid
language sql stable security definer set search_path = public, app, pg_temp as $$
  select family_id from guardians where user_id = auth.uid()
$$;

do $$
declare t text;
begin
  foreach t in array array['institutes','memberships','families','guardians','students','batches','enrollments','class_sessions','attendance','attendance_history',
    'lesson_credits','makeup_requests','student_invites','student_accounts','announcements','counters','invoices','invoice_lines','invoice_adjustments','payments','payment_invoices','payment_allocations','payment_proofs','receipts',
    'collection_cases','fee_links','notification_outbox','batch_costs','targets','import_batches','webhook_events','audit_events']
  loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- Staff with finance roles read everything in their institute.
do $$
declare t text;
begin
  foreach t in array array['families','guardians','students','batches','enrollments','class_sessions','lesson_credits','makeup_requests','announcements','invoices','payments','receipts',
    'collection_cases','notification_outbox','import_batches']
  loop
    execute format('grant select on public.%I to authenticated', t);
    execute format($p$create policy %I on public.%I for select to authenticated using (app.is_finance(institute_id))$p$, t || '_finance_read', t);
  end loop;
end $$;

-- institutes / memberships
grant select on public.institutes, public.memberships to authenticated;
create policy institutes_member_read on public.institutes for select to authenticated using (app.is_role(id, array['owner','admin','teacher','accountant']) or id in (select institute_id from public.families where id in (select app.my_family_ids())));
create policy memberships_read on public.memberships for select to authenticated using (user_id = auth.uid() or app.is_finance(institute_id));

-- tables without institute_id column
grant select on public.invoice_adjustments, public.lesson_credits, public.makeup_requests, public.announcements, public.invoice_lines, public.payment_allocations, public.payment_invoices, public.payment_proofs, public.attendance to authenticated;
create policy adj_finance_read on public.invoice_adjustments for select to authenticated using (exists (select 1 from public.invoices i where i.id = invoice_id and app.is_finance(i.institute_id)));
create policy lines_finance_read on public.invoice_lines for select to authenticated using (exists (select 1 from public.invoices i where i.id = invoice_id and app.is_finance(i.institute_id)));
create policy alloc_finance_read on public.payment_allocations for select to authenticated using (exists (select 1 from public.payments p where p.id = payment_id and app.is_finance(p.institute_id)));
create policy pinv_finance_read on public.payment_invoices for select to authenticated using (exists (select 1 from public.payments p where p.id = payment_id and app.is_finance(p.institute_id)));
create policy proofs_finance_read on public.payment_proofs for select to authenticated using (exists (select 1 from public.payments p where p.id = payment_id and app.is_finance(p.institute_id)));
create policy attendance_staff_read on public.attendance for select to authenticated using (exists (select 1 from public.class_sessions s where s.id = session_id and app.is_role(s.institute_id, array['owner','admin','teacher'])));

-- Teachers: only sessions (no fee data anywhere) – everything else through teacher RPCs.
create policy sessions_teacher_read on public.class_sessions for select to authenticated using (
  teacher_membership_id in (select id from public.memberships where user_id = auth.uid() and role = 'teacher' and status = 'active'));

-- Students: only their own linked records. Money tables stay closed to minors; adult self-billing goes through RPCs.
create or replace function app.my_student_ids() returns setof uuid
language sql stable security definer set search_path = public, app, pg_temp as $$
  select student_id from student_accounts where user_id = auth.uid() and revoked_at is null
$$;
grant select on public.student_accounts to authenticated;
create policy student_accounts_self on public.student_accounts for select to authenticated using (user_id = auth.uid() and revoked_at is null);
create policy students_self_read on public.students for select to authenticated using (id in (select app.my_student_ids()));
create or replace function app.my_batch_ids() returns setof uuid
language sql stable security definer set search_path = public, app, pg_temp as $$
  select e.batch_id from enrollments e
   where e.status = 'active' and (e.student_id in (select student_id from student_accounts where user_id = auth.uid() and revoked_at is null)
         or e.student_id in (select s.id from students s where s.family_id in (select family_id from guardians where user_id = auth.uid())))
$$;
create policy sessions_student_read on public.class_sessions for select to authenticated using (batch_id in (select app.my_batch_ids()));
create policy attendance_student_read on public.attendance for select to authenticated using (student_id in (select app.my_student_ids()));
create policy announcements_member_read on public.announcements for select to authenticated using (batch_id is null and exists (select 1 from app.my_batch_ids() x limit 1) or batch_id in (select app.my_batch_ids()));
create policy credits_self_read on public.lesson_credits for select to authenticated using (student_id in (select app.my_student_ids()) or student_id in (select id from public.students where family_id in (select app.my_family_ids())));
create policy makeup_self_read on public.makeup_requests for select to authenticated using (student_id in (select app.my_student_ids()) or student_id in (select id from public.students where family_id in (select app.my_family_ids())));

-- Guardians: only their own family's records.
create policy families_guardian_read on public.families for select to authenticated using (id in (select app.my_family_ids()));
create policy guardians_self_read on public.guardians for select to authenticated using (family_id in (select app.my_family_ids()));
create policy students_guardian_read on public.students for select to authenticated using (family_id in (select app.my_family_ids()));
create policy invoices_guardian_read on public.invoices for select to authenticated using (family_id in (select app.my_family_ids()));
create policy lines_guardian_read on public.invoice_lines for select to authenticated using (exists (select 1 from public.invoices i where i.id = invoice_id and i.family_id in (select app.my_family_ids())));
create policy payments_guardian_read on public.payments for select to authenticated using (family_id in (select app.my_family_ids()));
create policy receipts_guardian_read on public.receipts for select to authenticated using (family_id in (select app.my_family_ids()));

-- Private storage bucket for payment proofs and receipts (Supabase only; skipped on plain Postgres).
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('proofs', 'proofs', false, 5242880, array['image/jpeg','image/png','image/webp','application/pdf'])
    on conflict (id) do nothing;
  end if;
end $$;

-- Finance staff may read proofs belonging to their institute (objects are stored as <institute_id>/<payment_id>/<file>).
do $$
begin
  if exists (select 1 from information_schema.schemata where schema_name = 'storage') then
    execute $p$create policy proofs_staff_read on storage.objects for select to authenticated using (bucket_id = 'proofs' and app.is_finance(((storage.foldername(name))[1])::uuid))$p$;
  end if;
end $$;

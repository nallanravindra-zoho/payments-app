-- Function privileges: nothing is callable by default; grant exactly what each role needs.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname in ('public', 'app') and p.prokind = 'f'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
end $$;

grant usage on schema app to authenticated, anon, service_role;
grant usage on schema public to anon, authenticated, service_role;

-- helpers used inside RLS policies
grant execute on function app.is_role(uuid, text[]), app.is_finance(uuid), app.my_family_ids(), app.my_student_ids(), app.my_batch_ids(), app.today() to authenticated;

-- signed-in users
do $$
declare n text;
begin
  foreach n in array array[
    'my_context','bootstrap_owner','get_settings','save_business_profile','save_gst_settings','save_payment_settings','invite_staff','list_staff','create_batch','batch_options',
    'import_preview','import_commit','import_revert','wizard_context','check_enrolment','invoice_preview','enrol_student','issue_fee_link','revoke_fee_link','send_invitation',
    'calendar_range','list_batches','batch_detail','attendance_target','attendance_save','teachable_students','issue_lesson_credit',
    'issue_student_invite','activate_student','student_home','student_class','student_attendance','request_makeup','review_makeup','update_student_preferences','create_announcement',
    'family_bill','payment_history','payment_status','receipt_view','request_promise','promise_context',
    'inbox_summary','payment_detail','approve_payment','reject_payment','allocation_context','confirm_allocation','record_offline_payment','create_promise','remind_family','reverse_payment',
    'list_students','owner_student','owner_home','get_target','set_target','report_revenue','report_aging','report_profit','report_reconcile','report_gst','report_retention','report_export']
  loop
    execute format('grant execute on function public.%I to authenticated', n) ;
  end loop;
end $$;
-- the secure-link parent endpoints are the only anonymous surface (token is the credential)
grant execute on function public.family_bill(text, uuid, uuid), public.payment_history(text, uuid, uuid), public.payment_status(uuid, text, uuid), public.receipt_view(uuid, text), public.request_promise(text, uuid, date) to anon;

-- edge functions (service role only)
grant execute on all functions in schema public to service_role;
grant execute on all functions in schema app to service_role;
revoke execute on function public.my_context(), public.bootstrap_owner(text, text) from anon;

alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
alter default privileges in schema app revoke execute on functions from public, anon, authenticated;

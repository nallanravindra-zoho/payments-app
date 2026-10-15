-- DESTRUCTIVE: removes everything ClassPay created so all_migrations.sql can be run again from scratch.
-- It drops EVERY table and function in the "public" schema, so use it only on a project that holds no other data you want to keep.
-- It does NOT touch Supabase Auth users (auth.users).
do $$
declare r record;
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    begin perform cron.unschedule('classpay-daily'); exception when others then null; end;
  end if;
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    begin execute 'drop policy if exists proofs_staff_read on storage.objects'; exception when others then null; end;
  end if;
  drop schema if exists app cascade;
  for r in select tablename from pg_tables where schemaname = 'public' loop
    execute format('drop table if exists public.%I cascade', r.tablename);
  end loop;
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.prokind = 'f' loop
    execute 'drop function if exists ' || r.sig || ' cascade';
  end loop;
end $$;

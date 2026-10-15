-- Run this first. It only reads; it changes nothing.
select
  exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'institutes')                                   as main_migration_applied,
  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'memberships' and column_name = 'email')       as email_signin_applied,
  (select count(*) from public.institutes) as academies_with_data;

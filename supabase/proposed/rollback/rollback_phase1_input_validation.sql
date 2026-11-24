-- =====================================================================
-- ROLLBACK for phase1_input_validation.sql (PROPOSED — run only with approval).
-- Removes exactly what that migration created: the 8 "dorly_validate" triggers and its functions
-- (dorly_validate, and dorly_problem in its current 4-argument and earlier 3-argument forms).
-- The "dorly_guard" triggers, all policies and all data are left untouched. Safe to run more than once.
-- =====================================================================
begin;
set local lock_timeout = '5s';
drop trigger if exists dorly_validate on public.dorly_listings;
drop trigger if exists dorly_validate on public.dorly_sellers;
drop trigger if exists dorly_validate on public.dorly_inquiries;
drop trigger if exists dorly_validate on public.dorly_complaints;
drop trigger if exists dorly_validate on public.dorly_verifs;
drop trigger if exists dorly_validate on public.dorly_audit;
drop trigger if exists dorly_validate on public.dorly_seller_private;
drop trigger if exists dorly_validate on public.dorly_listing_private;
drop function if exists dorly_internal.dorly_validate();
drop function if exists dorly_internal.dorly_problem(text, text, jsonb);
drop function if exists dorly_internal.dorly_problem(text, text, jsonb, text);
do $chk$
begin
  if exists (select 1 from pg_trigger where tgname = 'dorly_validate') then raise exception 'rollback check: a dorly_validate trigger is still present'; end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'dorly_internal' and p.proname in ('dorly_validate','dorly_problem')) then
    raise exception 'rollback check: a validation function is still present';
  end if;
  if (select count(*) from pg_trigger where tgname = 'dorly_guard' and tgrelid::regclass::text like 'dorly\_%') < 8 then
    raise exception 'rollback check: guard triggers are not all present';
  end if;
end $chk$;
commit;

-- =====================================================================
-- ROLLBACK for phase0_restrict_complaints.sql (PROPOSED — run only with approval).
-- Restores the original production policy exactly as it was:
--   create policy "anyone can complain" on public.dorly_complaints as PERMISSIVE for INSERT to anon, authenticated with check (true);
-- Note: this RE-OPENS anonymous complaint inserts (finding V9). Safe to run more than once.
-- =====================================================================
begin;
drop policy if exists "members can complain" on public.dorly_complaints;
drop policy if exists "anyone can complain" on public.dorly_complaints;
create policy "anyone can complain" on public.dorly_complaints for insert to anon, authenticated with check (true);
commit;

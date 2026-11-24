-- =====================================================================
-- PROPOSED (not applied) — Phase 0 containment: stop anonymous inserts into dorly_complaints.
-- Verified: no page, script or Edge Function ever inserts complaints (no form, no code path; the only
-- complaint array in the pages is offline sample data from seed(), which is never called), so no feature
-- depends on anonymous submissions. Existing complaints are untouched.
-- Admin read/update/delete policies are unchanged.
-- Before (live):  "anyone can complain"  FOR INSERT TO anon, authenticated WITH CHECK (true)
-- After:          "members can complain" FOR INSERT TO authenticated      WITH CHECK (dorly_internal.dorly_active())
-- Safe to run more than once (one transaction; drops are IF EXISTS).
-- Rollback: rollback/rollback_phase0_restrict_complaints.sql
-- =====================================================================
begin;
set local lock_timeout = '5s';
drop policy if exists "anyone can complain" on public.dorly_complaints;
drop policy if exists "members can complain" on public.dorly_complaints;
create policy "members can complain" on public.dorly_complaints for insert to authenticated
  with check (dorly_internal.dorly_active());
commit;

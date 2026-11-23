-- =====================================================================
-- PROPOSED (not applied) — Phase 0 containment: stop anonymous inserts into dorly_complaints.
-- Verified: neither dorly.html nor admin.html ever inserts complaints (no form, no code path),
-- so no feature depends on anonymous submissions. Existing complaints (currently 0) are untouched.
-- Admin read/update/delete policies are unchanged.
-- Rollback:  drop policy "members can complain" on public.dorly_complaints;
--            create policy "anyone can complain" on public.dorly_complaints for insert to anon, authenticated with check (true);
-- =====================================================================
drop policy "anyone can complain" on public.dorly_complaints;
create policy "members can complain" on public.dorly_complaints for insert to authenticated
  with check (dorly_internal.dorly_active());

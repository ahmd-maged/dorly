-- trigger functions: never callable directly
revoke execute on function public.dorly_guard_profiles(), public.dorly_guard_sellers(), public.dorly_guard_private(),
  public.dorly_guard_listings(), public.dorly_guard_inquiries(), public.dorly_guard_complaints(), public.dorly_guard_verifs()
  from public, anon, authenticated;
-- helpers used by RLS policies: move out of the REST-exposed schema (policies keep working)
create schema if not exists dorly_internal;
grant usage on schema dorly_internal to anon, authenticated;
alter function public.dorly_privileged() set schema dorly_internal;
alter function public.dorly_active() set schema dorly_internal;
alter function public.dorly_owns_seller(text) set schema dorly_internal;
alter function public.dorly_keep(jsonb, jsonb, text[]) set schema dorly_internal;
alter function public.dorly_guard_profiles() set schema dorly_internal;
alter function public.dorly_guard_sellers() set schema dorly_internal;
alter function public.dorly_guard_private() set schema dorly_internal;
alter function public.dorly_guard_listings() set schema dorly_internal;
alter function public.dorly_guard_inquiries() set schema dorly_internal;
alter function public.dorly_guard_complaints() set schema dorly_internal;
alter function public.dorly_guard_verifs() set schema dorly_internal;
alter function dorly_internal.dorly_owns_seller(text) set search_path = public, dorly_internal;
alter function dorly_internal.dorly_guard_sellers() set search_path = public, dorly_internal;
alter function dorly_internal.dorly_guard_private() set search_path = public, dorly_internal;
alter function dorly_internal.dorly_guard_listings() set search_path = public, dorly_internal;
alter function dorly_internal.dorly_guard_inquiries() set search_path = public, dorly_internal;
alter function dorly_internal.dorly_guard_complaints() set search_path = public, dorly_internal;
alter function dorly_internal.dorly_guard_verifs() set search_path = public, dorly_internal;

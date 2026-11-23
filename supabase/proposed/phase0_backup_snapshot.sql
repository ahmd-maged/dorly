-- =====================================================================
-- PROPOSED (not applied) — Phase 0 backup: in-database snapshot of all Dorly data.
-- Creates a private schema that is NOT exposed through the REST/GraphQL API
-- (exposed schemas are only public, graphql_public) and grants nothing to browser roles.
-- Read-only with respect to live tables: it only copies them. Contains personal data — keep it private.
-- Restore example (per table, only if ever needed, after review):
--   insert into public.dorly_listings select * from dorly_backup_20261123.dorly_listings on conflict (id) do nothing;
-- Drop when no longer needed:  drop schema dorly_backup_20261123 cascade;
-- =====================================================================
create schema dorly_backup_20261123;
revoke all on schema dorly_backup_20261123 from public, anon, authenticated;
create table dorly_backup_20261123.dorly_profiles        as table public.dorly_profiles;
create table dorly_backup_20261123.dorly_sellers         as table public.dorly_sellers;
create table dorly_backup_20261123.dorly_seller_private  as table public.dorly_seller_private;
create table dorly_backup_20261123.dorly_listings        as table public.dorly_listings;
create table dorly_backup_20261123.dorly_listing_private as table public.dorly_listing_private;
create table dorly_backup_20261123.dorly_inquiries       as table public.dorly_inquiries;
create table dorly_backup_20261123.dorly_complaints      as table public.dorly_complaints;
create table dorly_backup_20261123.dorly_verifs          as table public.dorly_verifs;
create table dorly_backup_20261123.dorly_audit           as table public.dorly_audit;
-- file inventory only (names/metadata, not file contents)
create table dorly_backup_20261123.storage_objects as
  select bucket_id, name, owner, created_at, metadata from storage.objects where bucket_id in ('dorly-public','dorly-private');
revoke all on all tables in schema dorly_backup_20261123 from public, anon, authenticated;
-- verification: row counts in the snapshot vs live
select 'listings' t, (select count(*) from public.dorly_listings) live, (select count(*) from dorly_backup_20261123.dorly_listings) snap
union all select 'sellers', (select count(*) from public.dorly_sellers), (select count(*) from dorly_backup_20261123.dorly_sellers)
union all select 'profiles', (select count(*) from public.dorly_profiles), (select count(*) from dorly_backup_20261123.dorly_profiles)
union all select 'inquiries', (select count(*) from public.dorly_inquiries), (select count(*) from dorly_backup_20261123.dorly_inquiries);

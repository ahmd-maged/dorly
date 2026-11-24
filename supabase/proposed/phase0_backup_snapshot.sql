-- =====================================================================
-- PROPOSED (not applied) — Phase 0 backup: in-database snapshot of the Dorly app tables.
--
-- THIS IS NOT A COMPLETE DISASTER-RECOVERY BACKUP. It protects the app's table rows against a bad
-- migration or a bad bulk edit. It does NOT contain: Storage file contents (photos, screenshots,
-- documents), auth.users / logins, policies, functions, triggers, Edge Functions, secrets, or
-- project settings. See docs/BACKUP_AND_RECOVERY.md for the full checklist.
--
-- What it does: copies every dorly_* app table (all columns, all rows) into the private schema
-- dorly_backup_20261123, plus an inventory (names/metadata only) of the Dorly Storage buckets.
-- The schema is NOT exposed through the REST/GraphQL API and grants nothing to anon, authenticated
-- or service_role (only the owner, postgres, can read it). Contains personal data — keep it private
-- and drop it when no longer needed:  drop schema dorly_backup_20261123 cascade;
--
-- Effect on live data: read-only. CREATE TABLE AS takes only ACCESS SHARE locks on the live tables
-- (reads and writes continue; only DDL on those tables waits). REPEATABLE READ gives one consistent
-- snapshot across all tables. Re-running fails at CREATE SCHEMA on purpose, so a snapshot is never
-- overwritten; to take another one, change the schema name everywhere in this file.
-- Restore (only after review and approval): restore_from_backup.sql
-- Run as one script (SQL editor or psql).
-- =====================================================================
begin isolation level repeatable read;
create schema dorly_backup_20261123;
revoke all on schema dorly_backup_20261123 from public, anon, authenticated, service_role;
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
revoke all on all tables in schema dorly_backup_20261123 from public, anon, authenticated, service_role;
-- verification: row counts in the snapshot vs live (same transaction snapshot, so they must match)
select t, live, snap, live = snap as ok from (
            select 'profiles' t, (select count(*) from public.dorly_profiles) live, (select count(*) from dorly_backup_20261123.dorly_profiles) snap
  union all select 'sellers', (select count(*) from public.dorly_sellers), (select count(*) from dorly_backup_20261123.dorly_sellers)
  union all select 'seller_private', (select count(*) from public.dorly_seller_private), (select count(*) from dorly_backup_20261123.dorly_seller_private)
  union all select 'listings', (select count(*) from public.dorly_listings), (select count(*) from dorly_backup_20261123.dorly_listings)
  union all select 'listing_private', (select count(*) from public.dorly_listing_private), (select count(*) from dorly_backup_20261123.dorly_listing_private)
  union all select 'inquiries', (select count(*) from public.dorly_inquiries), (select count(*) from dorly_backup_20261123.dorly_inquiries)
  union all select 'complaints', (select count(*) from public.dorly_complaints), (select count(*) from dorly_backup_20261123.dorly_complaints)
  union all select 'verifs', (select count(*) from public.dorly_verifs), (select count(*) from dorly_backup_20261123.dorly_verifs)
  union all select 'audit', (select count(*) from public.dorly_audit), (select count(*) from dorly_backup_20261123.dorly_audit)
  union all select 'storage_objects', (select count(*) from storage.objects where bucket_id in ('dorly-public','dorly-private')), (select count(*) from dorly_backup_20261123.storage_objects)
) c;
commit;

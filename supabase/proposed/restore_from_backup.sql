-- =====================================================================
-- RESTORE from dorly_backup_20261123 (PROPOSED — DO NOT RUN without explicit approval).
-- Run as the table owner (postgres), e.g. in the SQL editor, as one script.
-- Re-inserts rows that are MISSING from the live tables; it never overwrites or deletes existing rows.
-- Triggers are disabled during the copy so the guard/validation triggers don't rewrite restored values
-- (e.g. reset status/owner); they are re-enabled before commit. Order follows the foreign keys.
-- Profiles whose auth user no longer exists will fail (auth.users is not in the backup), and the
-- whole restore then rolls back: restore those logins first, or remove such rows from the backup copy.
-- Restored listings reference photos by URL: if Storage files were lost too, restore them first (see
-- docs/BACKUP_AND_RECOVERY.md). Works with or without the dorly_validate trigger installed.
-- =====================================================================
begin;
set local lock_timeout = '5s';
alter table public.dorly_sellers         disable trigger user;
alter table public.dorly_seller_private  disable trigger user;
alter table public.dorly_listings        disable trigger user;
alter table public.dorly_listing_private disable trigger user;
alter table public.dorly_inquiries       disable trigger user;
alter table public.dorly_complaints      disable trigger user;
alter table public.dorly_verifs          disable trigger user;
alter table public.dorly_audit           disable trigger user;
alter table public.dorly_profiles        disable trigger user;
insert into public.dorly_profiles (id, role, name, phone, email, seller_id, disabled, created, created_at)
  select id, role, name, phone, email, seller_id, disabled, created, created_at from dorly_backup_20261123.dorly_profiles on conflict do nothing;
insert into public.dorly_sellers (id, owner, sample, data, created_at, updated_at)
  select id, owner, sample, data, created_at, updated_at from dorly_backup_20261123.dorly_sellers on conflict do nothing;
insert into public.dorly_seller_private (seller_id, owner, data, updated_at)
  select seller_id, owner, data, updated_at from dorly_backup_20261123.dorly_seller_private on conflict do nothing;
insert into public.dorly_listings (id, seller_id, owner, status, sample, data, created_at, updated_at)
  select id, seller_id, owner, status, sample, data, created_at, updated_at from dorly_backup_20261123.dorly_listings on conflict do nothing;
insert into public.dorly_listing_private (listing_id, owner, data, updated_at)
  select listing_id, owner, data, updated_at from dorly_backup_20261123.dorly_listing_private on conflict do nothing;
insert into public.dorly_inquiries (id, seller_id, sample, data, created_at)
  select id, seller_id, sample, data, created_at from dorly_backup_20261123.dorly_inquiries on conflict do nothing;
insert into public.dorly_complaints (id, sample, data, created_at)
  select id, sample, data, created_at from dorly_backup_20261123.dorly_complaints on conflict do nothing;
insert into public.dorly_verifs (id, seller_id, status, sample, data, created_at)
  select id, seller_id, status, sample, data, created_at from dorly_backup_20261123.dorly_verifs on conflict do nothing;
insert into public.dorly_audit (id, data, created_at)
  select id, data, created_at from dorly_backup_20261123.dorly_audit on conflict do nothing;
alter table public.dorly_sellers         enable trigger user;
alter table public.dorly_seller_private  enable trigger user;
alter table public.dorly_listings        enable trigger user;
alter table public.dorly_listing_private enable trigger user;
alter table public.dorly_inquiries       enable trigger user;
alter table public.dorly_complaints      enable trigger user;
alter table public.dorly_verifs          enable trigger user;
alter table public.dorly_audit           enable trigger user;
alter table public.dorly_profiles        enable trigger user;
-- every backed-up row must now exist live (by primary key); otherwise roll back
do $chk$
declare n bigint;
begin
  select count(*) into n from (
              (select id::text from dorly_backup_20261123.dorly_profiles except select id::text from public.dorly_profiles)
    union all (select id from dorly_backup_20261123.dorly_sellers except select id from public.dorly_sellers)
    union all (select seller_id from dorly_backup_20261123.dorly_seller_private except select seller_id from public.dorly_seller_private)
    union all (select id from dorly_backup_20261123.dorly_listings except select id from public.dorly_listings)
    union all (select listing_id from dorly_backup_20261123.dorly_listing_private except select listing_id from public.dorly_listing_private)
    union all (select id from dorly_backup_20261123.dorly_inquiries except select id from public.dorly_inquiries)
    union all (select id from dorly_backup_20261123.dorly_complaints except select id from public.dorly_complaints)
    union all (select id from dorly_backup_20261123.dorly_verifs except select id from public.dorly_verifs)
    union all (select id from dorly_backup_20261123.dorly_audit except select id from public.dorly_audit)) m;
  if n > 0 then raise exception 'restore check: % backed-up rows are still missing', n; end if;
end $chk$;
commit;

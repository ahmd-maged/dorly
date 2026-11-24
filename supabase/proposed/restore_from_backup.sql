-- =====================================================================
-- RESTORE from dorly_backup_20261123 (PROPOSED — DO NOT RUN without explicit approval).
-- Run as the table owner (postgres), e.g. in the SQL editor, as one script.
--
-- What it does: re-inserts rows that are MISSING from the live tables; it never overwrites or deletes
-- an existing row. Triggers are disabled during the copy (so the guard/validation triggers don't rewrite
-- the restored values, e.g. reset status or owner) and re-enabled before commit. While they are disabled,
-- other writes to these tables wait for this transaction (ALTER TABLE takes a lock that blocks them).
-- Order follows the foreign keys: profiles, sellers, seller_private, listings, listing_private, inquiries,
-- complaints, verifs, audit.
--
-- READ BEFORE RUNNING:
-- * A FULL restore brings back EVERY row that is missing now, including rows that were deliberately deleted
--   after the snapshot (a seller's own deletions, an admin's moderation, a user's request to remove data).
--   To bring back only specific rows, list them in dorly_restore_only below (selective restore).
-- * auth.users (logins) is NOT in the backup. profiles.id, and the owner column of sellers, seller_private,
--   listings and listing_private, reference auth.users: a row whose login no longer exists makes the whole
--   restore fail and roll back. Restore those logins first (full backup, docs/BACKUP_AND_RECOVERY.md §3),
--   or leave those rows out with a selective restore.
-- * Restored listings point to photos by URL: if Storage files were lost too, restore them first.
-- Works with or without the dorly_validate trigger installed.
-- =====================================================================
begin;
set local lock_timeout = '5s';
-- Selective restore (optional): add one line per row to bring back, using the table name and the row's key
-- (id; seller_id for dorly_seller_private; listing_id for dorly_listing_private). Leave it EMPTY to restore
-- every missing row. Example:
--   insert into dorly_restore_only values ('dorly_listings', 'L1795389507744'), ('dorly_listing_private', 'L1795389507744');
create temp table dorly_restore_only (tbl text not null, id text not null) on commit drop;
-- >>> selective restore lines go here <<<

alter table public.dorly_profiles         disable trigger user;
alter table public.dorly_sellers          disable trigger user;
alter table public.dorly_seller_private   disable trigger user;
alter table public.dorly_listings         disable trigger user;
alter table public.dorly_listing_private  disable trigger user;
alter table public.dorly_inquiries        disable trigger user;
alter table public.dorly_complaints       disable trigger user;
alter table public.dorly_verifs           disable trigger user;
alter table public.dorly_audit            disable trigger user;
insert into public.dorly_profiles (id, role, name, phone, email, seller_id, disabled, created, created_at)
  select id, role, name, phone, email, seller_id, disabled, created, created_at from dorly_backup_20261123.dorly_profiles b
  where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_profiles' and r.id = b.id::text))
  on conflict do nothing;
insert into public.dorly_sellers (id, owner, sample, data, created_at, updated_at)
  select id, owner, sample, data, created_at, updated_at from dorly_backup_20261123.dorly_sellers b
  where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_sellers' and r.id = b.id))
  on conflict do nothing;
insert into public.dorly_seller_private (seller_id, owner, data, updated_at)
  select seller_id, owner, data, updated_at from dorly_backup_20261123.dorly_seller_private b
  where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_seller_private' and r.id = b.seller_id))
  on conflict do nothing;
insert into public.dorly_listings (id, seller_id, owner, status, sample, data, created_at, updated_at)
  select id, seller_id, owner, status, sample, data, created_at, updated_at from dorly_backup_20261123.dorly_listings b
  where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_listings' and r.id = b.id))
  on conflict do nothing;
insert into public.dorly_listing_private (listing_id, owner, data, updated_at)
  select listing_id, owner, data, updated_at from dorly_backup_20261123.dorly_listing_private b
  where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_listing_private' and r.id = b.listing_id))
  on conflict do nothing;
insert into public.dorly_inquiries (id, seller_id, sample, data, created_at)
  select id, seller_id, sample, data, created_at from dorly_backup_20261123.dorly_inquiries b
  where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_inquiries' and r.id = b.id))
  on conflict do nothing;
insert into public.dorly_complaints (id, sample, data, created_at)
  select id, sample, data, created_at from dorly_backup_20261123.dorly_complaints b
  where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_complaints' and r.id = b.id))
  on conflict do nothing;
insert into public.dorly_verifs (id, seller_id, status, sample, data, created_at)
  select id, seller_id, status, sample, data, created_at from dorly_backup_20261123.dorly_verifs b
  where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_verifs' and r.id = b.id))
  on conflict do nothing;
insert into public.dorly_audit (id, data, created_at)
  select id, data, created_at from dorly_backup_20261123.dorly_audit b
  where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_audit' and r.id = b.id))
  on conflict do nothing;
alter table public.dorly_profiles         enable trigger user;
alter table public.dorly_sellers          enable trigger user;
alter table public.dorly_seller_private   enable trigger user;
alter table public.dorly_listings         enable trigger user;
alter table public.dorly_listing_private  enable trigger user;
alter table public.dorly_inquiries        enable trigger user;
alter table public.dorly_complaints       enable trigger user;
alter table public.dorly_verifs           enable trigger user;
alter table public.dorly_audit            enable trigger user;
-- every row that was to be restored must now exist live (by key); otherwise everything rolls back
do $chk$
declare n bigint;
begin
  select count(*) into n from (
              (select b.id::text from dorly_backup_20261123.dorly_profiles b where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_profiles' and r.id = b.id::text)) except select id::text from public.dorly_profiles)
    union all (select b.id from dorly_backup_20261123.dorly_sellers b where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_sellers' and r.id = b.id)) except select id from public.dorly_sellers)
    union all (select b.seller_id from dorly_backup_20261123.dorly_seller_private b where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_seller_private' and r.id = b.seller_id)) except select seller_id from public.dorly_seller_private)
    union all (select b.id from dorly_backup_20261123.dorly_listings b where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_listings' and r.id = b.id)) except select id from public.dorly_listings)
    union all (select b.listing_id from dorly_backup_20261123.dorly_listing_private b where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_listing_private' and r.id = b.listing_id)) except select listing_id from public.dorly_listing_private)
    union all (select b.id from dorly_backup_20261123.dorly_inquiries b where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_inquiries' and r.id = b.id)) except select id from public.dorly_inquiries)
    union all (select b.id from dorly_backup_20261123.dorly_complaints b where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_complaints' and r.id = b.id)) except select id from public.dorly_complaints)
    union all (select b.id from dorly_backup_20261123.dorly_verifs b where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_verifs' and r.id = b.id)) except select id from public.dorly_verifs)
    union all (select b.id from dorly_backup_20261123.dorly_audit b where (not exists (select 1 from dorly_restore_only) or exists (select 1 from dorly_restore_only r where r.tbl = 'dorly_audit' and r.id = b.id)) except select id from public.dorly_audit)) m;
  if n > 0 then raise exception 'restore check: % backed-up rows are still missing', n; end if;
end $chk$;
commit;

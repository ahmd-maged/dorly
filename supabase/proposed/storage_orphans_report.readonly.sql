-- =====================================================================
-- READ-ONLY report: Storage files in the Dorly buckets that no listing references any more
-- ("orphans" — e.g. photos uploaded for a listing whose save was rejected, or a listing deleted later).
-- It lists paths only; it deletes nothing. Cleanup is a separate, manual step (see
-- docs/BACKUP_AND_RECOVERY.md, "Orphaned uploads"): review the list, keep a copy, then delete through the
-- Storage API / dashboard, never with SQL DELETE on storage.objects.
-- Only files older than 24 hours are listed, so an upload whose listing is still being saved is never reported.
-- Verification documents are not uploaded to Storage (only file names are stored), so they cannot be orphans.
-- =====================================================================
with refs as (            -- every Storage path a listing points to (public photo URLs and private 'sbp:' references)
  select 'dorly-public' bucket, substring(v from '/object/public/dorly-public/(.+)$') path
    from public.dorly_listings l, jsonb_each_text(coalesce(l.data->'pubPhotos','{}'::jsonb)) e(k, v)
  union all
  select 'dorly-public', substring(v from '/object/public/dorly-public/(.+)$')
    from public.dorly_listings l, jsonb_array_elements_text(case when jsonb_typeof(l.data->'photos')='array' then l.data->'photos' else '[]'::jsonb end) v
  union all
  select 'dorly-private', substring(v from '^sbp:(.+)$')
    from public.dorly_listings l, jsonb_each_text(coalesce(l.data->'shots','{}'::jsonb)) e(k, v)
)
select o.bucket_id, o.name, o.created_at, (o.metadata->>'size')::bigint as bytes,
       split_part(o.name, '/', 3) as listing_id,
       exists (select 1 from public.dorly_listings l where l.id = split_part(o.name, '/', 3)) as listing_exists
from storage.objects o
where o.bucket_id in ('dorly-public', 'dorly-private')
  and o.created_at < now() - interval '24 hours'
  and not exists (select 1 from refs r where r.bucket = o.bucket_id and r.path = o.name)
order by o.created_at;

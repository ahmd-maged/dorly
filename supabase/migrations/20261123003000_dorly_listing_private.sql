-- Private per-listing details (WhatsApp contact number, IMEI): readable by the listing owner and admins only.
create table public.dorly_listing_private(
  listing_id text primary key references public.dorly_listings(id) on delete cascade,
  owner uuid references auth.users(id) on delete set null,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now());
create index on public.dorly_listing_private(owner);

create or replace function dorly_internal.dorly_guard_listing_private() returns trigger language plpgsql security definer
set search_path = public, dorly_internal as $$
begin
  if tg_op = 'UPDATE' then new.owner := old.owner; new.listing_id := old.listing_id;
  elsif not dorly_internal.dorly_privileged() then new.owner := auth.uid(); end if;
  new.updated_at := now(); return new; end $$;
revoke execute on function dorly_internal.dorly_guard_listing_private() from public, anon, authenticated;
create trigger dorly_guard before insert or update on public.dorly_listing_private for each row execute function dorly_internal.dorly_guard_listing_private();

alter table public.dorly_listing_private enable row level security;
create policy "owner or admin read" on public.dorly_listing_private for select to authenticated
  using (owner = auth.uid() or dorly_internal.dorly_privileged());
create policy "owner insert" on public.dorly_listing_private for insert to authenticated
  with check ((dorly_internal.dorly_active() and exists(select 1 from public.dorly_listings l where l.id = listing_id and l.owner = auth.uid()))
              or dorly_internal.dorly_privileged());
create policy "owner or admin update" on public.dorly_listing_private for update to authenticated
  using ((owner = auth.uid() and dorly_internal.dorly_active()) or dorly_internal.dorly_privileged())
  with check ((owner = auth.uid() and dorly_internal.dorly_active()) or dorly_internal.dorly_privileged());

-- WhatsApp number to contact about a listing: the listing's own number, else the seller's. Members only.
create or replace function public.dorly_listing_whatsapp(lid text) returns text language sql stable security definer
set search_path = public, dorly_internal as $$
  select case when dorly_internal.dorly_active() then
    coalesce(nullif(lp.data->>'whatsapp',''), nullif(sp.data->>'whatsapp','')) end
  from public.dorly_listings l
  left join public.dorly_listing_private lp on lp.listing_id = l.id
  left join public.dorly_seller_private sp on sp.seller_id = l.seller_id
  where l.id = lid and (l.status = 'active' or l.owner = auth.uid() or dorly_internal.dorly_privileged()) $$;
revoke all on function public.dorly_listing_whatsapp(text) from public, anon;
grant execute on function public.dorly_listing_whatsapp(text) to authenticated;

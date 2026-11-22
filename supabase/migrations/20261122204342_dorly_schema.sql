-- ===== Dorly marketplace schema (all objects prefixed dorly_) =====
create table public.dorly_profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('customer','individual','merchant','admin')),
  name text not null,
  phone text not null unique,
  email text not null default '',
  seller_id text,
  disabled boolean not null default false,
  created text,
  created_at timestamptz not null default now()
);
create unique index dorly_profiles_email_uq on public.dorly_profiles (lower(email)) where email <> '';

create table public.dorly_sellers(
  id text primary key, owner uuid references auth.users(id) on delete set null,
  sample boolean not null default false, data jsonb not null,
  created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default now());
create table public.dorly_seller_private(
  seller_id text primary key references public.dorly_sellers(id) on delete cascade,
  owner uuid references auth.users(id) on delete set null, data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now());
create table public.dorly_listings(
  id text primary key, seller_id text not null references public.dorly_sellers(id) on delete cascade,
  owner uuid references auth.users(id) on delete set null, status text not null,
  sample boolean not null default false, data jsonb not null,
  created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default now());
create table public.dorly_inquiries(
  id text primary key, seller_id text not null references public.dorly_sellers(id) on delete cascade,
  sample boolean not null default false, data jsonb not null,
  created_at timestamptz not null default clock_timestamp());
create table public.dorly_complaints(
  id text primary key, sample boolean not null default false, data jsonb not null,
  created_at timestamptz not null default clock_timestamp());
create table public.dorly_verifs(
  id text primary key, seller_id text not null references public.dorly_sellers(id) on delete cascade,
  status text not null default 'pending', sample boolean not null default false, data jsonb not null,
  created_at timestamptz not null default clock_timestamp());
create table public.dorly_audit(
  id text primary key, data jsonb not null, created_at timestamptz not null default clock_timestamp());

create index on public.dorly_listings(seller_id); create index on public.dorly_listings(owner); create index on public.dorly_listings(status);
create index on public.dorly_inquiries(seller_id); create index on public.dorly_verifs(seller_id);
create index on public.dorly_sellers(owner); create index on public.dorly_seller_private(owner);

-- ===== helpers =====
create or replace function public.dorly_privileged() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(auth.role(),'') = 'service_role'
      or exists(select 1 from public.dorly_profiles where id = auth.uid() and role = 'admin' and not disabled) $$;
create or replace function public.dorly_active() returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.dorly_profiles where id = auth.uid() and not disabled) $$;
create or replace function public.dorly_owns_seller(sid text) returns boolean language sql stable security definer set search_path = public as $$
  select public.dorly_active() and exists(select 1 from public.dorly_sellers where id = sid and owner = auth.uid()) $$;
-- keep protected keys of a jsonb object equal to the old row
create or replace function public.dorly_keep(newd jsonb, oldd jsonb, keys text[]) returns jsonb language plpgsql immutable set search_path = public as $$
declare k text; begin
  foreach k in array keys loop
    if oldd ? k then newd := jsonb_set(newd, array[k], oldd->k); else newd := newd - k; end if;
  end loop; return newd; end $$;

-- login helper: e-mail -> internal login id (phone based). Returns null when unknown.
create or replace function public.dorly_login_email(ident text) returns text language sql stable security definer set search_path = public as $$
  select 'p' || phone || '@phone.dorly.app' from public.dorly_profiles where email <> '' and lower(email) = lower(trim(ident)) limit 1 $$;
create or replace function public.dorly_taken(p_phone text, p_email text) returns text language sql stable security definer set search_path = public as $$
  select case when exists(select 1 from public.dorly_profiles where phone = p_phone) then 'phone'
              when coalesce(p_email,'') <> '' and exists(select 1 from public.dorly_profiles where email <> '' and lower(email) = lower(p_email)) then 'email'
              else null end $$;

-- ===== guard triggers (server-side business rules) =====
create or replace function public.dorly_guard_profiles() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(),'') = 'service_role' then return new; end if;
  if new.id = auth.uid() then raise exception 'cannot modify own profile status'; end if;
  -- admins may only toggle "disabled"
  new.role := old.role; new.name := old.name; new.phone := old.phone; new.email := old.email;
  new.seller_id := old.seller_id; new.created := old.created; new.id := old.id;
  return new; end $$;
create trigger dorly_guard before update on public.dorly_profiles for each row execute function public.dorly_guard_profiles();

create or replace function public.dorly_guard_sellers() returns trigger language plpgsql security definer set search_path = public as $$
declare b jsonb;
begin
  new.data := jsonb_set(new.data, '{id}', to_jsonb(new.id));
  if tg_op = 'UPDATE' then new.owner := old.owner; new.sample := old.sample; end if;
  new.updated_at := now();
  if public.dorly_privileged() then return new; end if;
  if tg_op = 'INSERT' then raise exception 'sellers are created at sign-up'; end if;
  -- owners can drop badges (e.g. renaming a verified shop) but never add them
  select coalesce(jsonb_agg(x), '[]'::jsonb) into b from jsonb_array_elements(coalesce(old.data->'badges','[]'::jsonb)) x
   where coalesce(new.data->'badges','[]'::jsonb) @> jsonb_build_array(x);
  new.data := public.dorly_keep(new.data, old.data, array['suspended','type','since','sample']);
  new.data := jsonb_set(new.data, '{badges}', b);
  return new; end $$;
create trigger dorly_guard before insert or update on public.dorly_sellers for each row execute function public.dorly_guard_sellers();

create or replace function public.dorly_guard_private() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then new.owner := old.owner; new.seller_id := old.seller_id;
  elsif not public.dorly_privileged() then new.owner := auth.uid(); end if;
  new.updated_at := now(); return new; end $$;
create trigger dorly_guard before insert or update on public.dorly_seller_private for each row execute function public.dorly_guard_private();

create or replace function public.dorly_guard_listings() returns trigger language plpgsql security definer set search_path = public as $$
declare os text; ns text;
begin
  new.data := jsonb_set(new.data, '{id}', to_jsonb(new.id));
  if tg_op = 'UPDATE' then
    new.owner := old.owner; new.sample := old.sample;
    new.data := jsonb_set(new.data, '{seller}', to_jsonb(old.seller_id));
  end if;
  new.seller_id := new.data->>'seller';
  new.updated_at := now();
  if not public.dorly_privileged() then
    if tg_op = 'INSERT' then
      new.owner := auth.uid(); new.sample := false;
      new.data := new.data || jsonb_build_object('status','pending','level',1,'reviewed',false,'insp',null,'sample',false)
                 - 'reason' - 'pausedByAdmin';
    else
      new.data := public.dorly_keep(new.data, old.data, array['level','reviewed','insp','reason','pausedByAdmin','sample']);
      os := old.data->>'status'; ns := new.data->>'status';
      if ns is distinct from os then
        if not ((ns in ('paused','sold') and os in ('active','paused','sold'))
             or (ns = 'active' and os in ('paused','sold') and not coalesce((old.data->>'pausedByAdmin')::boolean,false))) then
          raise exception 'status change % -> % not allowed', os, ns;
        end if;
      end if;
    end if;
  end if;
  new.status := new.data->>'status';
  return new; end $$;
create trigger dorly_guard before insert or update on public.dorly_listings for each row execute function public.dorly_guard_listings();

create or replace function public.dorly_guard_inquiries() returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.data := jsonb_set(new.data, '{id}', to_jsonb(new.id));
  if tg_op = 'UPDATE' then new.seller_id := old.seller_id; new.sample := old.sample; else new.seller_id := new.data->>'seller'; end if;
  if public.dorly_privileged() then return new; end if;
  if tg_op = 'INSERT' then
    new.sample := false;
    new.data := new.data || jsonb_build_object('status','new','sample',false);
  else
    if (new.data->>'status') not in ('new','read') then raise exception 'bad status'; end if;
    new.data := old.data || jsonb_build_object('status', new.data->'status');
  end if;
  return new; end $$;
create trigger dorly_guard before insert or update on public.dorly_inquiries for each row execute function public.dorly_guard_inquiries();

create or replace function public.dorly_guard_complaints() returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.data := jsonb_set(new.data, '{id}', to_jsonb(new.id));
  if tg_op = 'INSERT' and not public.dorly_privileged() then
    new.sample := false; new.data := new.data || jsonb_build_object('status','open','sample',false);
  end if;
  return new; end $$;
create trigger dorly_guard before insert or update on public.dorly_complaints for each row execute function public.dorly_guard_complaints();

create or replace function public.dorly_guard_verifs() returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.data := jsonb_set(new.data, '{id}', to_jsonb(new.id));
  if tg_op = 'UPDATE' then new.seller_id := old.seller_id; new.sample := old.sample; else new.seller_id := new.data->>'seller'; end if;
  if tg_op = 'INSERT' and not public.dorly_privileged() then
    new.sample := false; new.data := new.data || jsonb_build_object('status','pending','reason','','sample',false);
  end if;
  new.status := new.data->>'status';
  return new; end $$;
create trigger dorly_guard before insert or update on public.dorly_verifs for each row execute function public.dorly_guard_verifs();

-- ===== row level security =====
alter table public.dorly_profiles enable row level security;
alter table public.dorly_sellers enable row level security;
alter table public.dorly_seller_private enable row level security;
alter table public.dorly_listings enable row level security;
alter table public.dorly_inquiries enable row level security;
alter table public.dorly_complaints enable row level security;
alter table public.dorly_verifs enable row level security;
alter table public.dorly_audit enable row level security;

create policy "own or admin read" on public.dorly_profiles for select to authenticated using (id = auth.uid() or public.dorly_privileged());
create policy "admin update" on public.dorly_profiles for update to authenticated using (public.dorly_privileged()) with check (public.dorly_privileged());

create policy "public read" on public.dorly_sellers for select to anon, authenticated using (true);
create policy "owner or admin update" on public.dorly_sellers for update to authenticated
  using ((owner = auth.uid() and public.dorly_active()) or public.dorly_privileged())
  with check ((owner = auth.uid() and public.dorly_active()) or public.dorly_privileged());
create policy "admin delete" on public.dorly_sellers for delete to authenticated using (public.dorly_privileged());

create policy "owner or admin read" on public.dorly_seller_private for select to authenticated using (owner = auth.uid() or public.dorly_privileged());
create policy "owner insert" on public.dorly_seller_private for insert to authenticated with check (public.dorly_owns_seller(seller_id) or public.dorly_privileged());
create policy "owner or admin update" on public.dorly_seller_private for update to authenticated
  using ((owner = auth.uid() and public.dorly_active()) or public.dorly_privileged()) with check ((owner = auth.uid() and public.dorly_active()) or public.dorly_privileged());

create policy "read active or own" on public.dorly_listings for select to anon, authenticated
  using (status = 'active' or owner = auth.uid() or public.dorly_privileged());
create policy "seller insert" on public.dorly_listings for insert to authenticated
  with check ((owner = auth.uid() and public.dorly_owns_seller(seller_id)) or public.dorly_privileged());
create policy "owner or admin update" on public.dorly_listings for update to authenticated
  using ((owner = auth.uid() and public.dorly_active()) or public.dorly_privileged())
  with check ((owner = auth.uid() and public.dorly_owns_seller(seller_id)) or public.dorly_privileged());
create policy "owner or admin delete" on public.dorly_listings for delete to authenticated
  using ((owner = auth.uid() and public.dorly_active()) or public.dorly_privileged());

create policy "anyone can ask" on public.dorly_inquiries for insert to anon, authenticated
  with check (exists(select 1 from public.dorly_sellers s where s.id = seller_id));
create policy "seller or admin read" on public.dorly_inquiries for select to authenticated using (public.dorly_owns_seller(seller_id) or public.dorly_privileged());
create policy "seller or admin update" on public.dorly_inquiries for update to authenticated
  using (public.dorly_owns_seller(seller_id) or public.dorly_privileged()) with check (public.dorly_owns_seller(seller_id) or public.dorly_privileged());
create policy "admin delete" on public.dorly_inquiries for delete to authenticated using (public.dorly_privileged());

create policy "anyone can complain" on public.dorly_complaints for insert to anon, authenticated with check (true);
create policy "admin read" on public.dorly_complaints for select to authenticated using (public.dorly_privileged());
create policy "admin update" on public.dorly_complaints for update to authenticated using (public.dorly_privileged()) with check (public.dorly_privileged());
create policy "admin delete" on public.dorly_complaints for delete to authenticated using (public.dorly_privileged());

create policy "seller insert" on public.dorly_verifs for insert to authenticated with check (public.dorly_owns_seller(seller_id) or public.dorly_privileged());
create policy "seller or admin read" on public.dorly_verifs for select to authenticated using (public.dorly_owns_seller(seller_id) or public.dorly_privileged());
create policy "admin update" on public.dorly_verifs for update to authenticated using (public.dorly_privileged()) with check (public.dorly_privileged());
create policy "admin delete" on public.dorly_verifs for delete to authenticated using (public.dorly_privileged());

create policy "admin all" on public.dorly_audit for all to authenticated using (public.dorly_privileged()) with check (public.dorly_privileged());

-- RPCs callable from the browser
revoke all on function public.dorly_login_email(text) from public;
revoke all on function public.dorly_taken(text,text) from public;
grant execute on function public.dorly_login_email(text) to anon, authenticated;
grant execute on function public.dorly_taken(text,text) to anon, authenticated;

-- ===== storage =====
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('dorly-public','dorly-public', true, 5242880, array['image/jpeg','image/png','image/webp']),
       ('dorly-private','dorly-private', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do nothing;
create policy "dorly public upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'dorly-public' and public.dorly_active() and (storage.foldername(name))[1] = auth.uid()::text);
create policy "dorly private upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'dorly-private' and public.dorly_active() and (storage.foldername(name))[1] = auth.uid()::text);
create policy "dorly private read" on storage.objects for select to authenticated
  using (bucket_id = 'dorly-private' and ((storage.foldername(name))[1] = auth.uid()::text or public.dorly_privileged()));

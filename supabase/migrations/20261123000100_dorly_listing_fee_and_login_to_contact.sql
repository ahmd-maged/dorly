-- Listing fee (99 EGP): new listings start unpaid; only admins (or a future payment webhook using the
-- service role) can mark them paid; a listing can only go live once paid.
-- Sellers can resubmit a rejected listing (same id, payment kept); that resets its verification level.
create or replace function dorly_internal.dorly_guard_listings() returns trigger language plpgsql security definer
set search_path = public, dorly_internal as $$
declare os text; ns text;
begin
  new.data := jsonb_set(new.data, '{id}', to_jsonb(new.id));
  if tg_op = 'UPDATE' then
    new.owner := old.owner; new.sample := old.sample;
    new.data := jsonb_set(new.data, '{seller}', to_jsonb(old.seller_id));
  end if;
  new.seller_id := new.data->>'seller';
  new.updated_at := now();
  os := case when tg_op = 'UPDATE' then old.data->>'status' else null end;
  if not dorly_internal.dorly_privileged() then
    if tg_op = 'INSERT' then
      new.owner := auth.uid(); new.sample := false;
      new.data := new.data || jsonb_build_object('status','pending','level',1,'reviewed',false,'insp',null,'sample',false,
                    'pay', jsonb_build_object('amount',99,'currency','EGP','status','unpaid'))
                 - 'reason' - 'pausedByAdmin';
    else
      new.data := dorly_internal.dorly_keep(new.data, old.data, array['level','reviewed','insp','reason','pausedByAdmin','sample','pay']);
      ns := new.data->>'status';
      if ns is distinct from os then
        if ns = 'pending' and os = 'rejected' then
          -- resubmitted after edits: back to review at the base level
          new.data := (new.data || jsonb_build_object('level',1,'reviewed',false,'insp',null)) - 'reason';
        elsif not ((ns in ('paused','sold') and os in ('active','paused','sold'))
             or (ns = 'active' and os in ('paused','sold') and not coalesce((old.data->>'pausedByAdmin')::boolean,false))) then
          raise exception 'status change % -> % not allowed', os, ns;
        end if;
      end if;
    end if;
  end if;
  ns := new.data->>'status';
  -- nothing goes live before the fee is paid (rows without a "pay" object predate the fee)
  if ns = 'active' and os is distinct from 'active' and coalesce(new.data->'pay'->>'status','paid') <> 'paid' then
    raise exception 'listing fee not paid';
  end if;
  new.status := ns;
  return new; end $$;

-- contacting a seller now requires a signed-in, active account
drop policy "anyone can ask" on public.dorly_inquiries;
create policy "members can ask" on public.dorly_inquiries for insert to authenticated
  with check (dorly_internal.dorly_active() and exists(select 1 from public.dorly_sellers s where s.id = seller_id));

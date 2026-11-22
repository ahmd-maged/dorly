-- Seller WhatsApp numbers live in dorly_seller_private; signed-in, active members can fetch one to start a chat.
create or replace function public.dorly_seller_whatsapp(sid text) returns text language sql stable security definer
set search_path = public, dorly_internal as $$
  select case when dorly_internal.dorly_active() then nullif(p.data->>'whatsapp','') end
  from public.dorly_seller_private p where p.seller_id = sid $$;
revoke all on function public.dorly_seller_whatsapp(text) from public, anon;
grant execute on function public.dorly_seller_whatsapp(text) to authenticated;

-- one-time e-mail codes (only the dorly-otp Edge Function, with the service role, touches this table)
create table public.dorly_otp_codes(
  id bigserial primary key,
  target text not null,                 -- lower-cased e-mail
  purpose text not null check (purpose in ('signup','reset')),
  code_hash text not null,
  tries int not null default 0,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index on public.dorly_otp_codes(target, purpose, created_at desc);
alter table public.dorly_otp_codes enable row level security;   -- no policies: browsers can't read or write it
revoke all on public.dorly_otp_codes from anon, authenticated;

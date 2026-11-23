#!/usr/bin/env python3
"""Generates supabase/proposed/phase1_input_validation.sql (the migration) and, with --check,
a READ-ONLY query that evaluates the very same rules against existing rows. One rule list, two outputs."""
import sys

ID_RE = r'^[A-Za-z0-9_-]{1,64}$'
PUB_URL = r'^https://[a-z0-9]{20}\.supabase\.co/storage/v1/object/public/dorly-public/[0-9a-f-]{36}/listings/[A-Za-z0-9_-]{1,64}/[A-Za-z0-9_-]{1,40}\.(jpg|png|webp)$'
SHOT_REF = r'^sbp:[0-9a-f-]{36}/listings/[A-Za-z0-9_-]{1,64}/[A-Za-z0-9_-]{1,40}\.(jpg|png|webp)$'
GENS = ['2G','3G','3GS','4','4S','5','5c','5s','6','6s','7','8','SE','X','XR','XS','11','12','13','14','15','16','17','16e','17e','Air']
VARIANTS = ['', 'Plus', 'Pro', 'Pro Max', 'mini', 'Max', 'e', '2016', '2020', '2022']

q = lambda s: "'" + s.replace("'", "''") + "'"
arr = lambda xs: 'array[' + ','.join(q(x) for x in xs) + ']::text[]'

def present(k): return f"(D ? {q(k)} and jsonb_typeof(D->{q(k)}) <> 'null')"
def opt(k, cond, req=False): return f"(case when {present(k)} then ({cond}) else {'false' if req else 'true'} end)"
def TXT(k, n, req=False, minlen=0):
    return opt(k, f"jsonb_typeof(D->{q(k)})='string' and char_length(D->>{q(k)}) between {minlen} and {n}", req)
def RE(k, rx, req=False): return opt(k, f"jsonb_typeof(D->{q(k)})='string' and (D->>{q(k)}) ~ {q(rx)}", req)
def ENUM(k, xs, req=False): return opt(k, f"jsonb_typeof(D->{q(k)})='string' and (D->>{q(k)}) = any({arr(xs)})", req)
def INT(k, lo, hi, req=False):
    return opt(k, f"jsonb_typeof(D->{q(k)})='number' and (D->>{q(k)})::numeric between {lo} and {hi} and (D->>{q(k)})::numeric = trunc((D->>{q(k)})::numeric)", req)
def BOOL(k): return opt(k, f"jsonb_typeof(D->{q(k)})='boolean'")
def OBJ(k): return opt(k, f"jsonb_typeof(D->{q(k)})='object'")
def MAP(k, keys, rx):
    return opt(k, f"jsonb_typeof(D->{q(k)})='object' and not exists (select 1 from jsonb_each(D->{q(k)}) e where not (e.key = any({arr(keys)}) and (jsonb_typeof(e.value)='null' or (jsonb_typeof(e.value)='string' and (e.value#>>'{{}}') ~ {q(rx)}))))")
def ARR_ENUM(k, xs, maxn):
    return opt(k, f"jsonb_typeof(D->{q(k)})='array' and jsonb_array_length(D->{q(k)}) <= {maxn} and not exists (select 1 from jsonb_array_elements(D->{q(k)}) e where not (jsonb_typeof(e)='string' and (e#>>'{{}}') = any({arr(xs)})))")
def ARR_RE(k, rx, maxn):
    return opt(k, f"jsonb_typeof(D->{q(k)})='array' and jsonb_array_length(D->{q(k)}) <= {maxn} and not exists (select 1 from jsonb_array_elements(D->{q(k)}) e where not (jsonb_typeof(e)='string' and (e#>>'{{}}') ~ {q(rx)}))")
GEN = opt('gen', f"(jsonb_typeof(D->'gen')='number' and (D->>'gen')::numeric between 1 and 40 and (D->>'gen')::numeric = trunc((D->>'gen')::numeric)) or (jsonb_typeof(D->'gen')='string' and ((D->>'gen') = any({arr(GENS)}) or (D->>'gen') ~ '^[0-9]{{1,2}}$'))", True)
FLAT_STRINGS = lambda n: f"not exists (select 1 from jsonb_each(D) e where not (jsonb_typeof(e.value) in ('null','boolean') or (jsonb_typeof(e.value)='string' and char_length(e.value#>>'{{}}') <= {n})))"

RULES = {
 'dorly_listings': [
  ('seller', RE('seller', ID_RE, True)), ('gen', GEN), ('variant', ENUM('variant', VARIANTS)),
  ('storage', RE('storage', r'^[0-9]{1,4}(GB|TB)$', True)), ('battery', INT('battery', 0, 100, True)),
  ('price', INT('price', 1, 100000000, True)), ('cond', ENUM('cond', ['excellent','vgood','good'], True)),
  ('status', ENUM('status', ['active','pending','paused','sold','rejected'], True)), ('level', INT('level', 1, 4)),
  ('color', TXT('color', 40)), ('date', TXT('date', 40)), ('insp', TXT('insp', 40)), ('reason', TXT('reason', 200)),
  ('parts', TXT('parts', 300)), ('defects', TXT('defects', 300)), ('warranty', TXT('warranty', 100)), ('network', TXT('network', 100)),
  ('acc', ARR_ENUM('acc', ['box','charger','cable','invoice'], 4)),
  ('flags', ' and '.join(BOOL(k) for k in ['nego','icloud','reviewed','sample','wa','pausedByAdmin'])),
  ('pubPhotos', MAP('pubPhotos', ['front','back','sides','camera','defect'], PUB_URL)),
  ('photos', ARR_RE('photos', PUB_URL, 10)),
  ('shots', MAP('shots', ['battery','about','storage','parts'], SHOT_REF)),
  ('form', OBJ('form')),
  ('pay', opt('pay', "jsonb_typeof(D->'pay')='object' and coalesce(D->'pay'->>'status','unpaid') in ('unpaid','paid')")),
 ],
 'dorly_sellers': [
  ('name', TXT('name', 80, True, 1)), ('type', ENUM('type', ['merchant','individual'], True)), ('city', TXT('city', 160)),
  ('badges', ARR_ENUM('badges', ['email','phone','identity','merchant','trusted'], 5)), ('since', TXT('since', 10)),
  ('flags', BOOL('suspended') + ' and ' + BOOL('sample')),
  ('profile', opt('profile', "jsonb_typeof(D->'profile')='object' and not exists (select 1 from jsonb_each(D->'profile') e where not (jsonb_typeof(e.value) in ('null','boolean') or (jsonb_typeof(e.value)='string' and char_length(e.value#>>'{}') <= 500)))")),
  ('profile.web', opt('profile', "coalesce(D->'profile'->>'web','') = '' or (D->'profile'->>'web') ~ '^https?://[^\\s\"<>]{1,300}$'")),
 ],
 'dorly_inquiries': [
  ('seller', RE('seller', ID_RE, True)), ('listing', RE('listing', ID_RE)), ('name', TXT('name', 80)), ('phone', TXT('phone', 30)),
  ('msg', TXT('msg', 2000)), ('time', TXT('time', 40)), ('status', ENUM('status', ['new','read'], True)), ('flags', BOOL('sample')),
 ],
 'dorly_complaints': [
  ('against', RE('against', ID_RE)), ('by', TXT('by', 80)), ('text', TXT('text', 2000)),
  ('status', ENUM('status', ['open','resolved'], True)), ('flags', BOOL('sample')),
 ],
 'dorly_verifs': [
  ('seller', RE('seller', ID_RE, True)), ('kind', ENUM('kind', ['merchant','identity'], True)),
  ('status', ENUM('status', ['pending','approved','rejected'], True)), ('reason', TXT('reason', 200)), ('time', TXT('time', 40)),
  ('docs', opt('docs', "jsonb_typeof(D->'docs')='array' and jsonb_array_length(D->'docs') <= 10 and not exists (select 1 from jsonb_array_elements(D->'docs') x where not (jsonb_typeof(x)='object' and coalesce(jsonb_typeof(x->'label'),'string')='string' and char_length(coalesce(x->>'label','')) <= 60 and coalesce(jsonb_typeof(x->'name'),'string')='string' and char_length(coalesce(x->>'name','')) <= 120))")),
  ('flags', BOOL('sample')),
 ],
 'dorly_audit': [('t', opt('t', "jsonb_typeof(D->'t')='number'")), ('by', TXT('by', 80)), ('txt', TXT('txt', 1000))],
 'dorly_seller_private': [('values', FLAT_STRINGS(300))],
 'dorly_listing_private': [('values', FLAT_STRINGS(300))],
}

def problem_expr(D, RID, TBL):
    parts = [f"when {RID} is null or {RID} !~ {q(ID_RE)} then 'id'",
             f"when jsonb_typeof({D}) is distinct from 'object' then 'data'",
             f"when pg_column_size({D}) > 100000 then 'data size'"]
    for t, rules in RULES.items():
        inner = ' '.join(f"when not ({c}) then {q(n)}" for n, c in rules)
        parts.append(f"when {TBL} = {q(t)} then (case {inner} else null end)")
    return ('case ' + '\n  '.join(parts) + ' else null end').replace('D->', f'{D}->').replace('(D ?', f'({D} ?').replace('jsonb_each(D)', f'jsonb_each({D})')

TABLES_ID = ['dorly_listings','dorly_sellers','dorly_inquiries','dorly_complaints','dorly_verifs','dorly_audit']

def migration():
    return f"""-- =====================================================================
-- PROPOSED (not applied): Phase 1 server-side input validation for Dorly.
-- Adds a second BEFORE trigger "dorly_validate" on every dorly_* table that holds app data.
-- Triggers of the same timing fire in name order, so it runs AFTER "dorly_guard"
-- (which rewrites protected fields) and checks the final row.
-- It applies to everyone (sellers, customers, admins, service role): only well-formed data is stored.
-- Rejected writes fail with SQLSTATE 23514 (check_violation) and message 'dorly: invalid <field>'.
-- No existing row is modified. Existing rows are only re-checked if they are updated later.
-- Generated by tools/gen_validation_sql.py — edit the rules there, not here.
-- =====================================================================

create or replace function dorly_internal.dorly_problem(tbl text, rid text, d jsonb) returns text
language sql immutable set search_path = pg_catalog as $$
  select {problem_expr('d', 'rid', 'tbl')}
$$;

create or replace function dorly_internal.dorly_validate() returns trigger language plpgsql security definer
set search_path = pg_catalog, public, dorly_internal as $$
declare rid text; p text;
begin
  rid := coalesce(to_jsonb(new)->>'id', to_jsonb(new)->>'seller_id', to_jsonb(new)->>'listing_id');
  -- record IDs never change (prevents planting values through a primary-key update)
  if tg_op = 'UPDATE' and rid is distinct from coalesce(to_jsonb(old)->>'id', to_jsonb(old)->>'seller_id', to_jsonb(old)->>'listing_id') then
    raise exception using errcode = 'check_violation', message = 'dorly: id cannot change', hint = tg_table_name;
  end if;
  p := dorly_internal.dorly_problem(tg_table_name, rid, new.data);
  if p is not null then
    raise exception using errcode = 'check_violation', message = 'dorly: invalid ' || p, hint = tg_table_name;
  end if;
  return new;
end $$;

revoke execute on function dorly_internal.dorly_validate() from public, anon, authenticated;
revoke execute on function dorly_internal.dorly_problem(text, text, jsonb) from public, anon, authenticated;

""" + '\n'.join(f"create trigger dorly_validate before insert or update on public.{t} for each row execute function dorly_internal.dorly_validate();"
                for t in TABLES_ID + ['dorly_seller_private', 'dorly_listing_private']) + "\n"

def check_query():
    sel = []
    for t in TABLES_ID: sel.append(f"select {q(t)} tbl, id rid, data d from public.{t}")
    sel.append("select 'dorly_seller_private', seller_id, data from public.dorly_seller_private")
    sel.append("select 'dorly_listing_private', listing_id, data from public.dorly_listing_private")
    return ("-- READ-ONLY: evaluates the proposed rules against existing rows. Returns table, id and the first failing rule only.\n"
            "with r as (\n  " + "\n  union all ".join(sel) + "\n)\nselect tbl, rid, " + problem_expr('d', 'rid', 'tbl') + " as problem from r order by tbl, rid;\n")

if __name__ == '__main__':
    print(check_query() if '--check' in sys.argv else migration())

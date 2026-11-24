#!/usr/bin/env python3
"""Generates supabase/proposed/phase1_input_validation.sql (the migration) and, with --check,
a READ-ONLY query that evaluates the very same rules against existing rows. One rule list, two outputs."""
import re, sys

ID_RE = r'^[A-Za-z0-9_-]{1,64}$'
# Supabase project whose Storage may hold Dorly media. Production by default; a staging database must be
# generated with its own project:  python3 tools/gen_validation_sql.py --project-ref <ref>
PROJECT_REF = next((a.split('=', 1)[1] for a in sys.argv if a.startswith('--project-ref=')), 'sayqxowybxpqmqfshmqk')
assert re.fullmatch(r'[a-z0-9]{20}', PROJECT_REF), 'project ref must be 20 lowercase letters/digits'
# Media paths are <owner uid>/listings/<listing id>/<name>.<ext> (see uploadMedia in assets/dorly-cloud.js).
# OWNER and RID are filled in per row: the folder must be the listing owner's and the listing's own id, so a
# listing can neither point at another project nor reuse another user's (or another listing's) files.
# If a listing has no owner any more (account deleted) only the project and file-name shape are checked.
MEDIA_TAIL = r"/listings/' || RID || '/[A-Za-z0-9_-]{1,40}\.(jpg|png|webp)$'"
MEDIA_PUBLIC = r"('^https://" + PROJECT_REF + r"\.supabase\.co/storage/v1/object/public/dorly-public/' || coalesce(OWNER, '[0-9a-f-]{36}') || '" + MEDIA_TAIL + ")"
MEDIA_PRIVATE = r"('^sbp:' || coalesce(OWNER, '[0-9a-f-]{36}') || '" + MEDIA_TAIL + ")"
PRICE_MIN, PRICE_MAX = 1000, 300000       # whole pounds; the same range in dorly.html and admin.html (PRICE)
GENS = ['2G','3G','3GS','4','4S','5','5c','5s','6','6s','7','8','SE','X','XR','XS','11','12','13','14','15','16','17','16e','17e','Air']
VARIANTS = ['', 'Plus', 'Pro', 'Pro Max', 'mini', 'Max', 'e', '2016', '2020', '2022']

# Server-side limits. The pages enforce the same (or tighter) limits before saving, with a visible message:
#   parts/defects = fixed answer text + ' — ' + note (note <= 500 in the publish form, <= 1000 in the admin edit form)
#   doc_label     = fixed label, or 'مراجعة تغيير اسم النشاط إلى: ' + business name (<= 80)  -> < 200
#   doc_name      = the uploaded file's name (<= 255, the usual file-system maximum; longer names get an error)
#   web           = http(s) link; the pages add https:// when it is missing
LIM = {'parts': 1000, 'defects': 1000, 'doc_label': 200, 'doc_name': 255, 'web': 300}

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
def MAP(k, keys, rx_expr):
    return opt(k, f"jsonb_typeof(D->{q(k)})='object' and not exists (select 1 from jsonb_each(D->{q(k)}) e where not (e.key = any({arr(keys)}) and (jsonb_typeof(e.value)='null' or (jsonb_typeof(e.value)='string' and (e.value#>>'{{}}') ~ {rx_expr}))))")
def ARR_ENUM(k, xs, maxn):
    return opt(k, f"jsonb_typeof(D->{q(k)})='array' and jsonb_array_length(D->{q(k)}) <= {maxn} and not exists (select 1 from jsonb_array_elements(D->{q(k)}) e where not (jsonb_typeof(e)='string' and (e#>>'{{}}') = any({arr(xs)})))")
def ARR_RE(k, rx_expr, maxn):
    return opt(k, f"jsonb_typeof(D->{q(k)})='array' and jsonb_array_length(D->{q(k)}) <= {maxn} and not exists (select 1 from jsonb_array_elements(D->{q(k)}) e where not (jsonb_typeof(e)='string' and (e#>>'{{}}') ~ {rx_expr}))")
GEN = opt('gen', f"(jsonb_typeof(D->'gen')='number' and (D->>'gen')::numeric between 1 and 40 and (D->>'gen')::numeric = trunc((D->>'gen')::numeric)) or (jsonb_typeof(D->'gen')='string' and ((D->>'gen') = any({arr(GENS)}) or (D->>'gen') ~ '^[0-9]{{1,2}}$'))", True)
FLAT_STRINGS = lambda n: f"not exists (select 1 from jsonb_each(D) e where not (jsonb_typeof(e.value) in ('null','boolean') or (jsonb_typeof(e.value)='string' and char_length(e.value#>>'{{}}') <= {n})))"

RULES = {
 'dorly_listings': [
  ('seller', RE('seller', ID_RE, True)), ('gen', GEN), ('variant', ENUM('variant', VARIANTS)),
  ('storage', RE('storage', r'^[0-9]{1,4}(GB|TB)$', True)), ('battery', INT('battery', 0, 100, True)),
  ('price', INT('price', PRICE_MIN, PRICE_MAX, True)), ('cond', ENUM('cond', ['excellent','vgood','good'], True)),
  ('status', ENUM('status', ['active','pending','paused','sold','rejected'], True)), ('level', INT('level', 1, 4)),
  ('color', TXT('color', 40)), ('date', TXT('date', 40)), ('insp', TXT('insp', 40)), ('reason', TXT('reason', 200)),
  ('parts', TXT('parts', LIM['parts'])), ('defects', TXT('defects', LIM['defects'])), ('warranty', TXT('warranty', 100)), ('network', TXT('network', 100)),
  ('acc', ARR_ENUM('acc', ['box','charger','cable','invoice'], 4)),
  ('flags', ' and '.join(BOOL(k) for k in ['nego','icloud','reviewed','sample','wa','pausedByAdmin'])),
  ('pubPhotos', MAP('pubPhotos', ['front','back','sides','camera','defect'], MEDIA_PUBLIC)),
  ('photos', ARR_RE('photos', MEDIA_PUBLIC, 10)),
  ('shots', MAP('shots', ['battery','about','storage','parts'], MEDIA_PRIVATE)),
  ('form', OBJ('form')),
  ('pay', opt('pay', "jsonb_typeof(D->'pay')='object' and coalesce(D->'pay'->>'status','unpaid') in ('unpaid','paid')")),
 ],
 'dorly_sellers': [
  ('name', TXT('name', 80, True, 1)), ('type', ENUM('type', ['merchant','individual'], True)), ('city', TXT('city', 160)),
  ('badges', ARR_ENUM('badges', ['email','phone','identity','merchant','trusted'], 5)), ('since', TXT('since', 10)),
  ('flags', BOOL('suspended') + ' and ' + BOOL('sample')),
  ('profile', opt('profile', "jsonb_typeof(D->'profile')='object' and not exists (select 1 from jsonb_each(D->'profile') e where not (jsonb_typeof(e.value) in ('null','boolean') or (jsonb_typeof(e.value)='string' and char_length(e.value#>>'{}') <= 500)))")),
  ('profile.web', opt('profile', f"coalesce(D->'profile'->>'web','') = '' or ((D->'profile'->>'web') ~ '^https?://[^\\s\"<>]+$' and char_length(D->'profile'->>'web') <= {LIM['web']})")),
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
  ('docs', opt('docs', f"jsonb_typeof(D->'docs')='array' and jsonb_array_length(D->'docs') <= 10 and not exists (select 1 from jsonb_array_elements(D->'docs') x where not (jsonb_typeof(x)='object' and coalesce(jsonb_typeof(x->'label'),'string')='string' and char_length(coalesce(x->>'label','')) <= {LIM['doc_label']} and coalesce(jsonb_typeof(x->'name'),'string')='string' and char_length(coalesce(x->>'name','')) <= {LIM['doc_name']}))")),
  ('flags', BOOL('sample')),
 ],
 'dorly_audit': [('t', opt('t', "jsonb_typeof(D->'t')='number'")), ('by', TXT('by', 80)), ('txt', TXT('txt', 1000))],
 'dorly_seller_private': [('values', FLAT_STRINGS(300))],
 'dorly_listing_private': [('values', FLAT_STRINGS(300))],
}

def problem_expr(D, RID, TBL, OWN):
    parts = [f"when {RID} is null or {RID} !~ {q(ID_RE)} then 'id'",
             f"when jsonb_typeof({D}) is distinct from 'object' then 'data'",
             f"when pg_column_size({D}) > 100000 then 'data size'"]
    for t, rules in RULES.items():
        inner = ' '.join(f"when not ({c}) then {q(n)}" for n, c in rules)
        parts.append(f"when {TBL} = {q(t)} then (case {inner} else null end)")
    out = ('case ' + '\n  '.join(parts) + ' else null end').replace('D->', f'{D}->').replace('(D ?', f'({D} ?').replace('jsonb_each(D)', f'jsonb_each({D})')
    # media rules: owner folder and listing id (the id was already checked against ID_RE above, so it is regex-safe;
    # the owner is a uuid column, i.e. only hex digits and dashes)
    return out.replace('OWNER', OWN).replace("' || RID || '", f"' || {RID} || '")

TABLES_ID = ['dorly_listings','dorly_sellers','dorly_inquiries','dorly_complaints','dorly_verifs','dorly_audit']

ALL_TABLES = TABLES_ID + ['dorly_seller_private', 'dorly_listing_private']
GUARDED = [t for t in ALL_TABLES if t != 'dorly_audit']     # tables that already have the "dorly_guard" BEFORE trigger

def migration():
    tl = arr(ALL_TABLES); gl = arr(GUARDED)
    triggers = '\n'.join(f"drop trigger if exists dorly_validate on public.{t};\n"
                         f"create trigger dorly_validate before insert or update on public.{t} for each row execute function dorly_internal.dorly_validate();"
                         for t in ALL_TABLES)
    return f"""-- =====================================================================
-- PROPOSED (not applied): Phase 1 server-side input validation for Dorly.
-- Target: Supabase project database, PostgreSQL 17 (works on PostgreSQL 12+; does NOT use CREATE OR REPLACE TRIGGER).
-- Media URLs are only accepted from Supabase project {PROJECT_REF} (regenerate with --project-ref=<ref> for staging),
-- inside the listing owner's folder and the listing's own folder.
-- Adds a second BEFORE trigger "dorly_validate" on every dorly_* table that holds app data.
-- Triggers of the same timing fire in name order, so it runs AFTER the existing "dorly_guard"
-- (which rewrites protected fields) and checks the final row. The guard triggers are not touched.
-- It applies to everyone (sellers, customers, admins, service role): only well-formed data is stored.
-- Rejected writes fail with SQLSTATE 23514 (check_violation) and message 'dorly: invalid <field>'.
-- No existing row is read or modified. Existing rows are only re-checked if they are updated later.
--
-- Safe to run more than once: functions use CREATE OR REPLACE, triggers are dropped (if present) and
-- re-created inside ONE transaction, so there is never a moment without validation and a failure
-- anywhere rolls everything back. The checks at the start and end abort the transaction if the
-- database is not in the expected state. Rollback: rollback/rollback_phase1_input_validation.sql
-- Run it as one script (SQL editor or psql). Generated by tools/gen_validation_sql.py — edit the rules there.
-- =====================================================================
begin;
set local lock_timeout = '5s';          -- never queue behind a long transaction while holding table locks

-- ---------- pre-check: the objects this migration relies on exist ----------
do $chk$
declare t text;
begin
  if to_regnamespace('dorly_internal') is null then raise exception 'pre-check: schema dorly_internal missing'; end if;
  foreach t in array {tl} loop
    if to_regclass('public.' || t) is null then raise exception 'pre-check: table % missing', t; end if;
  end loop;
  foreach t in array {gl} loop
    if not exists (select 1 from pg_trigger where tgrelid = ('public.' || t)::regclass and tgname = 'dorly_guard' and not tgisinternal) then
      raise exception 'pre-check: guard trigger dorly_guard missing on %', t;
    end if;
  end loop;
end $chk$;

-- owner: the listing's owner (auth uid) for dorly_listings, so media paths can be tied to it; null elsewhere
create or replace function dorly_internal.dorly_problem(tbl text, rid text, d jsonb, owner text) returns text
language sql immutable set search_path = pg_catalog, pg_temp as $$
  select {problem_expr('d', 'rid', 'tbl', 'owner')}
$$;

-- search_path holds only pg_catalog (and pg_temp last, as recommended for SECURITY DEFINER functions):
-- every Dorly object it uses is schema-qualified, so nothing can be shadowed by objects in other schemas.
create or replace function dorly_internal.dorly_validate() returns trigger language plpgsql security definer
set search_path = pg_catalog, pg_temp as $$
declare rid text; p text;
begin
  rid := coalesce(to_jsonb(new)->>'id', to_jsonb(new)->>'seller_id', to_jsonb(new)->>'listing_id');
  -- record IDs never change (prevents planting values through a primary-key update)
  if tg_op = 'UPDATE' and rid is distinct from coalesce(to_jsonb(old)->>'id', to_jsonb(old)->>'seller_id', to_jsonb(old)->>'listing_id') then
    raise exception using errcode = 'check_violation', message = 'dorly: id cannot change', hint = tg_table_name;
  end if;
  p := dorly_internal.dorly_problem(tg_table_name, rid, new.data, case when tg_table_name = 'dorly_listings' then to_jsonb(new)->>'owner' end);
  if p is not null then
    raise exception using errcode = 'check_violation', message = 'dorly: invalid ' || p, hint = tg_table_name;
  end if;
  return new;
end $$;

-- owned by postgres (same owner as the existing guard functions); nobody else may call them directly.
-- Triggers still fire for every role: PostgreSQL does not check EXECUTE when a trigger runs.
-- the earlier 3-argument version (from a previous run of this migration) is no longer used
drop function if exists dorly_internal.dorly_problem(text, text, jsonb);
alter function dorly_internal.dorly_problem(text, text, jsonb, text) owner to postgres;
alter function dorly_internal.dorly_validate() owner to postgres;
revoke all on function dorly_internal.dorly_validate() from public, anon, authenticated, service_role;
revoke all on function dorly_internal.dorly_problem(text, text, jsonb, text) from public, anon, authenticated, service_role;

{triggers}

-- ---------- post-check: abort (and roll back everything) unless the result is exactly as intended ----------
do $chk$
declare t text; last_before text;
begin
  if not exists (select 1 from pg_proc where oid = 'dorly_internal.dorly_validate()'::regprocedure
                 and prosecdef and proconfig @> array['search_path=pg_catalog, pg_temp']) then
    raise exception 'post-check: dorly_validate must be SECURITY DEFINER with a fixed search_path';
  end if;
  if not exists (select 1 from pg_proc where oid = 'dorly_internal.dorly_problem(text,text,jsonb,text)'::regprocedure
                 and not prosecdef and proconfig @> array['search_path=pg_catalog, pg_temp']) then
    raise exception 'post-check: dorly_problem must have a fixed search_path';
  end if;
  if has_function_privilege('anon', 'dorly_internal.dorly_validate()', 'execute')
     or has_function_privilege('authenticated', 'dorly_internal.dorly_validate()', 'execute')
     or has_function_privilege('anon', 'dorly_internal.dorly_problem(text,text,jsonb,text)', 'execute')
     or has_function_privilege('authenticated', 'dorly_internal.dorly_problem(text,text,jsonb,text)', 'execute') then
    raise exception 'post-check: browser roles can still execute the validation functions';
  end if;
  if to_regprocedure('dorly_internal.dorly_problem(text,text,jsonb)') is not null then
    raise exception 'post-check: the old 3-argument dorly_problem still exists';
  end if;
  foreach t in array {tl} loop
    if not exists (select 1 from pg_trigger where tgrelid = ('public.' || t)::regclass and tgname = 'dorly_validate'
                   and tgenabled = 'O' and tgtype = 23) then        -- 23 = ROW + BEFORE + INSERT + UPDATE
      raise exception 'post-check: dorly_validate missing or not BEFORE INSERT/UPDATE FOR EACH ROW on %', t;
    end if;
    -- the validation must be the LAST before-row trigger, so it sees what the guard stored
    select max(tgname collate "C") into last_before from pg_trigger
     where tgrelid = ('public.' || t)::regclass and not tgisinternal and (tgtype & 3) = 3;
    if last_before is distinct from 'dorly_validate' then
      raise exception 'post-check: % runs after dorly_validate on %', last_before, t;
    end if;
  end loop;
  foreach t in array {gl} loop
    if not exists (select 1 from pg_trigger where tgrelid = ('public.' || t)::regclass and tgname = 'dorly_guard' and tgenabled = 'O') then
      raise exception 'post-check: guard trigger changed on %', t;
    end if;
  end loop;
end $chk$;

commit;
"""

def check_query():
    sel = []
    for t in TABLES_ID: sel.append(f"select {q(t)} tbl, id rid, data d, {'owner::text' if t == 'dorly_listings' else 'null::text'} own from public.{t}")
    sel.append("select 'dorly_seller_private', seller_id, data, null::text from public.dorly_seller_private")
    sel.append("select 'dorly_listing_private', listing_id, data, null::text from public.dorly_listing_private")
    return ("-- READ-ONLY: evaluates the proposed rules against existing rows (media rules for project " + PROJECT_REF + "). Returns table, id and the first failing rule only.\n"
            "with r as (\n  " + "\n  union all ".join(sel) + "\n)\nselect tbl, rid, " + problem_expr('d', 'rid', 'tbl', 'own') + " as problem from r order by tbl, rid;\n")

def _selfcheck(sql):
    # PostgreSQL regexes allow at most 255 repetitions ({m,n} with n > 255 is an error at run time)
    import re
    bad = [m for m in re.findall(r'\{(\d+)(?:,(\d+))?\}', sql) if max(int(x or 0) for x in m) > 255]
    assert not bad, f'regex repetition count above 255: {bad}'
    return sql

if __name__ == '__main__':
    print(_selfcheck(check_query() if '--check' in sys.argv else migration()))

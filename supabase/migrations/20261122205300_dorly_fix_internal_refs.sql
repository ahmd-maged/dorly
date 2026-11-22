-- function bodies still referenced public.dorly_*(): point them at dorly_internal
do $$
declare f record; def text;
begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'dorly_internal' and p.prokind = 'f' loop
    def := pg_get_functiondef(f.oid);
    if def ~ 'public\.dorly_(privileged|active|owns_seller|keep)\(' then
      def := regexp_replace(def, 'public\.dorly_(privileged|active|owns_seller|keep)\(', 'dorly_internal.dorly_\1(', 'g');
      execute def;
    end if;
  end loop;
end $$;

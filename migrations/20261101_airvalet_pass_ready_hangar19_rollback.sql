-- Rollback of 20261101: Ready comes only from staff again.
begin;
do $$
declare v text := pg_get_functiondef('public.airvalet_portal_view(text,text)'::regprocedure);
begin
  if position('HANGAR 19 on the return day' in v) > 0 then
    v := replace(v,
      '    -- HANGAR 19 on the return day (owner 2026-10-25)' || chr(10) ||
      '    when v_pickup = ''HANGAR_19'' and upper(btrim(coalesce(v_p.loc, ''''))) = ''HANGAR 19''' || chr(10) ||
      '         and (public.airvalet_return_at(v_p.ret, null) at time zone ''America/New_York'')::date = (now() at time zone ''America/New_York'')::date then ''READY''' || chr(10), '');
    execute v;
  end if;
end $$;
commit;

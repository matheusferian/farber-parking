-- Valet pass "Ready" from the car's location (owner 2026-10-25): a Hangar 19
-- return shows READY when the car is in HANGAR 19 and today (America/New_York)
-- is the return date. A car parked in Hangar 19 for the whole trip shows Ready
-- only on the return day. Staff "ready" (pass state) keeps working as before.
begin;
do $$
declare v text := pg_get_functiondef('public.airvalet_portal_view(text,text)'::regprocedure);
begin
  if position('HANGAR 19 on the return day' in v) = 0 then
    v := replace(v,
      '    when v_st.ready_at is not null then ''READY''' || chr(10),
      '    when v_st.ready_at is not null then ''READY''' || chr(10) ||
      '    -- HANGAR 19 on the return day (owner 2026-10-25)' || chr(10) ||
      '    when v_pickup = ''HANGAR_19'' and upper(btrim(coalesce(v_p.loc, ''''))) = ''HANGAR 19''' || chr(10) ||
      '         and (public.airvalet_return_at(v_p.ret, null) at time zone ''America/New_York'')::date = (now() at time zone ''America/New_York'')::date then ''READY''' || chr(10));
    if position('HANGAR 19 on the return day' in v) = 0 then raise exception 'portal view patch point not found'; end if;
    execute v;
  end if;
end $$;
commit;

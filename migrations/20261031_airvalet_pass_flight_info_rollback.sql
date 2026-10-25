-- Rollback of 20261031: the valet pass stops showing flight / arrival time.
begin;
do $$
declare v text := pg_get_functiondef('public.airvalet_portal_view(text,text)'::regprocedure);
begin
  if position('''return_flight''' in v) > 0 then
    v := replace(v, chr(10) || '      ''return_flight'', nullif(upper(btrim(coalesce(v_p.return_flight, ''''))), ''''),', '');
    v := replace(v, chr(10) || '      ''arrival_time'', case when btrim(coalesce(v_p.departure_time, '''')) ~ ''^([01]?[0-9]|2[0-3]):[0-5][0-9]$'' then btrim(v_p.departure_time) end,', '');
    execute v;
  end if;
end $$;
commit;

-- Valet pass shows the return flight and arrival time once staff fill them on
-- the car card (owner 2026-10-25): passengers.return_flight (tail / flight)
-- and passengers.departure_time (HH:MM). Display only; nothing else changes.
begin;
do $$
declare v text := pg_get_functiondef('public.airvalet_portal_view(text,text)'::regprocedure);
begin
  if position('''return_flight''' in v) = 0 then
    v := replace(v,
      '''return_time'', to_char(v_p.ret_time, ''HH24:MI''),',
      '''return_time'', to_char(v_p.ret_time, ''HH24:MI''),' || chr(10) ||
      '      ''return_flight'', nullif(upper(btrim(coalesce(v_p.return_flight, ''''))), ''''),' || chr(10) ||
      '      ''arrival_time'', case when btrim(coalesce(v_p.departure_time, '''')) ~ ''^([01]?[0-9]|2[0-3]):[0-5][0-9]$'' then btrim(v_p.departure_time) end,');
    if position('''return_flight''' in v) = 0 then raise exception 'portal view patch point not found'; end if;
    execute v;
  end if;
end $$;
commit;

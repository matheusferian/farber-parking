-- Makers board for TV Mode (2026-11-06, owner): the TV shows Makers departures for today and tomorrow
-- and, on the Leaving Today / Leaving Tomorrow cards, which Makers flight each of our guests comes from.
-- airvalet_makers_board() reads the latest successful makers-sync result for today and for tomorrow
-- (America/New_York) and returns ONLY: departures (flight, route, tail, time, pax count, day trips,
-- Ascend) and, per AirValet passenger matched on an arriving flight, that flight's origin, tail and
-- FXE arrival time. No names of other travellers. Allowed for the ops roles and TV_ONLY.
--
-- airvalet_manifest_latest() (app screen) now prefers the latest DAY (tomorrow before today), then
-- the latest reading of that day, so a manual "today" reading never hides tomorrow's list.
begin;
set local lock_timeout = '5s';

create or replace function public.airvalet_makers_board()
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare v_today date := (now() at time zone 'America/New_York')::date; v jsonb := '{}'::jsonb; d date; s record;
begin
  if auth.uid() is null or public.current_user_role() is null
     or not (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER','TV_ONLY']::public.account_role[])) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  foreach d in array array[v_today, v_today + 1] loop
    select m.created_at, m.result into s
      from public.airvalet_manifest_scans m
     where m.usage->>'mode' = 'makers_sync' and coalesce((m.usage->>'ok')::boolean, false) and m.service_date = d
     order by m.created_at desc limit 1;
    if found then
      v := v || jsonb_build_object(case when d = v_today then 'today' else 'tomorrow' end, jsonb_build_object(
        'date', d, 'at', s.created_at,
        'outbound', coalesce(s.result->'outbound', '[]'::jsonb),
        'origins', coalesce((
          select jsonb_agg(jsonb_build_object('passenger_id', x->'passenger_id', 'flight', x->>'flight_number', 'route', x->>'route',
                   'registration', x->>'registration', 'arrival_time', x->>'arrival_time', 'ascend', coalesce((x->>'ascend')::boolean, false)))
            from jsonb_array_elements(coalesce(s.result->'matches', '[]'::jsonb)) x
           where x->>'kind' <> 'surname_only'), '[]'::jsonb)));
    end if;
  end loop;
  return v;
end $function$;
revoke all on function public.airvalet_makers_board() from public, anon;
grant execute on function public.airvalet_makers_board() to authenticated;

create or replace function public.airvalet_manifest_latest()
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare v jsonb;
begin
  perform public.airvalet_portal_require_ops();
  select jsonb_build_object('created_at', s.created_at, 'service_date', s.service_date,
           'ok', coalesce((s.usage->>'ok')::boolean, false), 'result', s.result)
    into v
    from public.airvalet_manifest_scans s
   where s.usage->>'mode' = 'makers_sync'
     and s.service_date >= (now() at time zone 'America/New_York')::date
   order by s.service_date desc, s.created_at desc limit 1;
  return v;
end $function$;

commit;

-- TV (owner 2026-11-06: "tomorrow 6:45 had 9, now 6 — show 9 struck through and 6"): each day also returns
-- `first_outbound` — the departures (flight, route, pax count) of the FIRST good robot reading of that day,
-- i.e. the list that went to the staff group (test readings before the 2:05 PM count fix are skipped).
-- Counts only. Everything else as 20261141.
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
        'outbound', coalesce((select jsonb_agg(f - 'ids') from jsonb_array_elements(coalesce(s.result->'outbound', '[]'::jsonb)) f), '[]'::jsonb),
        'first_outbound', coalesce((select jsonb_agg(jsonb_build_object('flight', f->'flight', 'route', f->'route', 'pax', f->'pax'))
                    from jsonb_array_elements(coalesce((select m0.result->'outbound' from public.airvalet_manifest_scans m0
                      where m0.usage->>'mode' = 'makers_sync' and coalesce((m0.usage->>'ok')::boolean, false) and m0.service_date = d
                        -- readings before the unique-passenger count fix (2026-11-06 2:05 PM ET) counted round trips twice
                        and m0.created_at >= timestamptz '2026-11-06 19:05:00+00'
                      order by m0.created_at asc limit 1), '[]'::jsonb)) f), '[]'::jsonb),
        'inbound', coalesce((select jsonb_agg(jsonb_build_object('flight', f->'flight', 'route', f->'route', 'tail', f->'tail', 'time', f->'time',
                      'dep', f->'dep', 'pax', f->'pax', 'ascend', f->'ascend'))
                    from jsonb_array_elements(coalesce(s.result->'inbound', '[]'::jsonb)) f where coalesce((f->>'pax')::int, 0) > 0), '[]'::jsonb),
        'changes', case when jsonb_typeof(s.result->'changes') = 'object'
                        then jsonb_build_object('since', s.result->'changes'->'since', 'items', coalesce(s.result->'changes'->'items', '[]'::jsonb)) end,
        'origins', coalesce((
          select jsonb_agg(jsonb_build_object('passenger_id', x->'passenger_id', 'flight', x->>'flight_number', 'route', x->>'route',
                   'registration', x->>'registration', 'arrival_time', x->>'arrival_time', 'ascend', coalesce((x->>'ascend')::boolean, false),
                   'dep_time', (select f->>'dep' from jsonb_array_elements(coalesce(s.result->'inbound', '[]'::jsonb)) f
                                 where f->>'flight' = x->>'flight_number' limit 1)))
            from jsonb_array_elements(coalesce(s.result->'matches', '[]'::jsonb)) x
           where x->>'kind' <> 'surname_only'), '[]'::jsonb)));
    end if;
  end loop;
  return v;
end $function$;
revoke all on function public.airvalet_makers_board() from public, anon;
grant execute on function public.airvalet_makers_board() to authenticated;
commit;

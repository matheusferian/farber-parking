-- TV (owner 2026-11-06): the board also returns each day's INBOUND Makers flights (flight, route, tail,
-- island departure, FXE arrival, passenger COUNT, Ascend) so the TV shows every aircraft coming to FXE with
-- passengers, not only the ones carrying our guests (e.g. WM from Cat Island, 5 pax). Counts only, no names.
-- Everything else as 20261138.
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

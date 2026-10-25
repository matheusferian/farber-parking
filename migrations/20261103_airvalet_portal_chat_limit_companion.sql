-- Two fixes from the 2026-10-25 audit (owner GO required before prod).
-- 1. Passenger chat froze after ~4 min: it polls every few seconds and every
--    call counted toward the 30-per-10-min client brake. Raise that brake to
--    150. The failed-lookup brake (8 per client, 2000 global) is unchanged and
--    is what stops token guessing.
-- 2. A companion sharing a phone with an earlier check-in got no welcome text
--    (DUPLICATE_RECENT / PREVIOUS_UNCONFIRMED). Each CHECK_IN carries its own
--    pass link, so for CHECK_IN those two checks only look at the same passenger.
begin;
do $$
declare v text := pg_get_functiondef('public.airvalet_portal_resolve(text,text)'::regprocedure);
begin
  if position('c_client_max   constant int := 150;' in v) = 0 then
    v := replace(v, 'c_client_max   constant int := 30;', 'c_client_max   constant int := 150;');
    if position('c_client_max   constant int := 150;' in v) = 0 then raise exception 'portal resolve patch point not found'; end if;
    execute v;
  end if;
end $$;
do $$
declare v text := pg_get_functiondef('public.airvalet_sms_claim(text,bigint,text,text,text,text,text,text,integer,text,uuid,integer,integer,text,bytea)'::regprocedure);
begin
  if position('companion check-in' in v) = 0 then
    v := replace(v,
      '                   and m.status in (''pending'', ''send_unknown'') and m.resolved_at is null' || chr(10),
      '                   and m.status in (''pending'', ''send_unknown'') and m.resolved_at is null' || chr(10) ||
      '                   and (p_message_type <> ''CHECK_IN'' or m.passenger_id is not distinct from p_passenger_id)  -- companion check-in: own link' || chr(10));
    v := replace(v,
      '                   and m.created_at > now() - interval ''2 minutes''' || chr(10),
      '                   and m.created_at > now() - interval ''2 minutes''' || chr(10) ||
      '                   and (p_message_type <> ''CHECK_IN'' or m.passenger_id is not distinct from p_passenger_id)  -- companion check-in: own link' || chr(10));
    if (length(v) - length(replace(v, 'companion check-in', ''))) / length('companion check-in') <> 2 then
      raise exception 'sms claim patch points not found';
    end if;
    execute v;
  end if;
end $$;
commit;

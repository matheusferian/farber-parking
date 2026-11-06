-- Rollback of 20261127: production definition read 2026-11-06.
begin;
set local lock_timeout = '5s';
CREATE OR REPLACE FUNCTION public.event_valet_staff(p_token text, p_session uuid, p_op text, p_body jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  a public.event_valet_access; ev public.event_valet_events; s public.event_valet_sessions; t public.event_valet_tickets;
  b jsonb := coalesce(p_body, '{}'::jsonb); v_ck text; v_res jsonb; v_prev public.event_valet_ops; v_n int;
  v_hook int; v_phone text; v_vehicle text; v_loc text; v_no int; v_code text; v_i int := 0; v_at timestamptz;
  v_to text; v_from text; v_who text; v_tip public.event_valet_tips; v_amt int; v_q text; v_digits text; v_notify text;
  v_actor jsonb; v_until timestamptz;
begin
  -- auth: token → access → event (+ session for everything but /session)
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$' then perform public._ev_err('AUTH'); end if;
  select * into a from public.event_valet_access where token_hash = sha256(convert_to(p_token, 'UTF8'));
  if not found then perform public._ev_err('AUTH'); end if;
  if a.revoked_at is not null then perform public._ev_err('REVOKED'); end if;
  if now() < a.valid_from or now() >= a.valid_until then perform public._ev_err('OUTSIDE_WINDOW'); end if;
  select * into ev from public.event_valet_events where id = a.event_id;
  if not ev.is_open or ev.closed_at is not null then perform public._ev_err('EVENT_CLOSED'); end if;
  if not ev.staff_access_enabled then perform public._ev_err('OUTSIDE_WINDOW', '{"why":"staff_access_off"}'); end if;
  insert into public.event_valet_rate (access_id, bucket, n) values (a.id, date_trunc('minute', now()), 1)
  on conflict (access_id, bucket) do update set n = public.event_valet_rate.n + 1 returning n into v_n;
  if v_n > 240 then perform public._ev_err('RATE_LIMIT'); end if;
  update public.event_valet_access set last_seen_at = now() where id = a.id;

  if p_op = 'session' then
    if length(btrim(coalesce(b->>'name', ''))) not between 2 and 40 then perform public._ev_err('BAD_INPUT', '{"field":"name"}'); end if;
    insert into public.event_valet_sessions (access_id, employee_name) values (a.id, initcap(btrim(b->>'name'))) returning * into s;
    insert into public.event_valet_audit (event_id, action, detail)
    values (ev.id, 'STAFF_SESSION', jsonb_build_object('actor', jsonb_build_object('access_id', a.id, 'kind', a.kind, 'label', a.label, 'employee_name', s.employee_name)));
    return jsonb_build_object('sessionId', s.id, 'employeeName', s.employee_name,
      'access', jsonb_build_object('kind', a.kind, 'label', a.label,
        'pool', jsonb_build_array(lower(case when a.kind = 'DEVICE' then ev.device_pool else ev.phone_pool end),
                                  upper(case when a.kind = 'DEVICE' then ev.device_pool else ev.phone_pool end) - 1)));
  end if;

  select * into s from public.event_valet_sessions where id = p_session and access_id = a.id and ended_at is null;
  if not found then perform public._ev_err('AUTH', '{"why":"session"}'); end if;
  v_actor := jsonb_build_object('access_id', a.id, 'kind', a.kind, 'label', a.label, 'employee_name', s.employee_name, 'session_id', s.id);

  -- read-only ops
  if p_op = 'state' then
    if b ? 'pending' and (b->>'pending') ~ '^\d{1,4}$' then
      update public.event_valet_access set pending_ops = (b->>'pending')::int, pending_at = now() where id = a.id;
    end if;
    return jsonb_build_object('serverTime', now(),
      'event', jsonb_build_object('id', ev.id, 'title', ev.title, 'date', ev.event_date, 'isOpen', ev.is_open,
        'locations', to_jsonb(ev.locations), 'capacity', ev.slot_capacity,
        'flags', jsonb_build_object('staffAccess', ev.staff_access_enabled, 'customerSms', ev.sms_enabled,
          'smsReplies', ev.sms_replies_enabled, 'tips', ev.tip_enabled, 'thanks', ev.thanks_enabled)),
      'me', jsonb_build_object('kind', a.kind, 'label', a.label, 'employeeName', s.employee_name, 'validUntil', a.valid_until),
      'counts', public._ev_counts(ev),
      'pools', jsonb_build_object('device', jsonb_build_array(lower(ev.device_pool), upper(ev.device_pool) - 1),
                                  'phone',  jsonb_build_array(lower(ev.phone_pool),  upper(ev.phone_pool) - 1)),
      'tickets', coalesce((select jsonb_agg(public.event_valet_staff_ticket(x) order by x.slot_no nulls last, x.ticket_no)
                             from public.event_valet_tickets x
                            where x.event_id = ev.id and (x.status <> 'DELIVERED' or x.delivered_at > now() - interval '60 minutes')), '[]'::jsonb));
  end if;
  if p_op = 'search' then
    v_q := btrim(coalesce(b->>'q', '')); v_digits := regexp_replace(v_q, '\D', '', 'g');
    if length(v_q) = 0 then return jsonb_build_object('tickets', '[]'::jsonb); end if;
    return jsonb_build_object('tickets', coalesce((select jsonb_agg(public.event_valet_staff_ticket(q.x) order by ((q.x).status = 'DELIVERED'), (q.x).slot_no)
      from (select x from public.event_valet_tickets x
             where x.event_id = ev.id and (x.status <> 'DELIVERED' or x.delivered_at > now() - interval '60 minutes')
               and ((v_q ~ '^#?\d{1,2}$' and x.slot_no = v_digits::int and x.status <> 'DELIVERED')
                 or (length(v_digits) >= 3 and v_digits = regexp_replace(v_q, '[\s()+-]', '', 'g')
                     and (x.phone_e164 like '%' || v_digits or x.ticket_code = v_digits))
                 or (v_q !~ '^[\d\s()#+-]+$' and (x.vehicle ilike '%' || v_q || '%' or replace(coalesce(x.vehicle_plate, ''), ' ', '') ilike '%' || replace(v_q, ' ', '') || '%')))
             limit 20) q), '[]'::jsonb));
  end if;

  -- mutating ops: idempotent per (access, clientKey)
  v_ck := b->>'clientKey';
  if v_ck is null or length(v_ck) not between 8 and 80 then perform public._ev_err('BAD_INPUT', '{"field":"clientKey"}'); end if;
  -- lock order everywhere: event row, then ticket (also serialises replays of one clientKey)
  select * into ev from public.event_valet_events where id = a.event_id for update;
  select * into v_prev from public.event_valet_ops where access_id = a.id and client_key = v_ck;
  if found then
    if v_prev.op <> p_op then perform public._ev_err('BAD_INPUT', '{"field":"clientKey","why":"reused"}'); end if;
    return v_prev.result || jsonb_build_object('replayed', true);
  end if;

  if p_op = 'hold' then
    delete from public.event_valet_holds where event_id = ev.id and held_until <= now();
    select hook into v_hook from public.event_valet_holds where event_id = ev.id and access_id = a.id and client_key = v_ck;
    if v_hook is null then
      v_hook := public._ev_alloc(ev, a.kind, v_ck);
      if v_hook is null then perform public._ev_err('HOOK_TAKEN', '{"suggestedHook":null,"why":"full"}'); end if;
      insert into public.event_valet_holds (event_id, hook, access_id, client_key, held_until)
      values (ev.id, v_hook, a.id, v_ck, now() + interval '3 minutes');
    else
      update public.event_valet_holds set held_until = now() + interval '3 minutes' where event_id = ev.id and hook = v_hook;
    end if;
    -- holds are not stored in ops: a later checkin with the same clientKey must still run
    return jsonb_build_object('hook', v_hook, 'heldUntil', now() + interval '3 minutes');

  elsif p_op = 'checkin' then
    v_phone := public.event_valet_normalize_phone(b->>'phone');
    if v_phone is null then perform public._ev_err('BAD_INPUT', '{"field":"phone"}'); end if;
    v_vehicle := public._ev_vehicle_text(coalesce(b->'vehicle', '{}'::jsonb));
    if length(v_vehicle) = 0 or length(v_vehicle) > 60 then perform public._ev_err('BAD_INPUT', '{"field":"vehicle"}'); end if;
    v_loc := b->>'location';
    if v_loc is null or not (v_loc = any (ev.locations)) then perform public._ev_err('BAD_INPUT', '{"field":"location"}'); end if;
    if b->>'keyStoredAt' is null then perform public._ev_err('BAD_INPUT', '{"field":"keyStoredAt"}'); end if;
    -- a retry of the same check-in that reached the DB through another path
    select * into t from public.event_valet_tickets where event_id = ev.id and client_key = v_ck;
    if found then
      v_res := jsonb_build_object('ticket', public.event_valet_staff_ticket(t), 'ticketId', t.id);
      insert into public.event_valet_ops values (a.id, v_ck, p_op, v_res); return v_res;
    end if;
    delete from public.event_valet_holds where event_id = ev.id and held_until <= now();
    if b->>'hook' is not null then
      if (b->>'hook') !~ '^\d{1,3}$' then perform public._ev_err('BAD_INPUT', '{"field":"hook"}'); end if;
      v_hook := (b->>'hook')::int;
      if not public._ev_hook_allowed(ev, a.kind, v_hook) then perform public._ev_err('BAD_INPUT', '{"field":"hook","why":"not_your_pool"}'); end if;
      if not public._ev_hook_free(ev, v_hook, v_ck) then
        perform public._ev_err('HOOK_TAKEN', jsonb_build_object('hook', v_hook, 'suggestedHook', public._ev_alloc(ev, a.kind, v_ck)));
      end if;
    else
      select hook into v_hook from public.event_valet_holds where event_id = ev.id and access_id = a.id and client_key = v_ck;
      if v_hook is null then v_hook := public._ev_alloc(ev, a.kind, v_ck); end if;
      if v_hook is null then perform public._ev_err('HOOK_TAKEN', '{"suggestedHook":null,"why":"full"}'); end if;
    end if;
    select coalesce(max(ticket_no), 0) + 1 into v_no from public.event_valet_tickets where event_id = ev.id;
    v_code := right(v_phone, 4);
    while exists (select 1 from public.event_valet_tickets where event_id = ev.id and ticket_code = v_code) loop
      v_i := v_i + 1;
      if v_i > 9 then perform public._ev_err('BAD_INPUT', '{"field":"phone","why":"too_many_cars"}'); end if;
      v_code := v_i::text || right(v_phone, 4);
    end loop;
    begin v_at := (b->>'keyStoredAt')::timestamptz; exception when others then v_at := now(); end;
    if v_at > now() + interval '2 minutes' or v_at < now() - interval '12 hours' then v_at := now(); end if;
    insert into public.event_valet_tickets (event_id, ticket_no, ticket_code, slot_no, phone_e164, vehicle, client_key,
        checked_in_at, parking_location, vehicle_color, vehicle_make, vehicle_model, vehicle_plate, key_stored_at,
        offline_checkin, checked_in_by, checked_in_access)
    values (ev.id, v_no, v_code, v_hook, v_phone, v_vehicle, v_ck,
        case when coalesce((b->>'offline')::boolean, false) then v_at else now() end, v_loc,
        nullif(upper(btrim(b#>>'{vehicle,color}')), ''), nullif(upper(btrim(b#>>'{vehicle,make}')), ''),
        nullif(upper(btrim(b#>>'{vehicle,model}')), ''), nullif(upper(regexp_replace(btrim(coalesce(b#>>'{vehicle,plate}', '')), '\s+', ' ', 'g')), ''),
        v_at, coalesce((b->>'offline')::boolean, false), s.employee_name, a.id)
    returning * into t;
    delete from public.event_valet_holds where event_id = ev.id and client_key = v_ck;
    insert into public.event_valet_audit (event_id, ticket_id, action, detail)
    values (ev.id, t.id, 'CHECK_IN', jsonb_build_object('actor', v_actor, 'hook', v_hook, 'offline', t.offline_checkin, 'ticket_no', v_no));
    v_res := jsonb_build_object('ticket', public.event_valet_staff_ticket(t), 'ticketId', t.id, 'notify', 'CHECKIN');

  elsif p_op in ('move-hook', 'status', 'edit') then
    if (b->>'ticketId') !~ '^[0-9a-f-]{36}$' then perform public._ev_err('BAD_INPUT', '{"field":"ticketId"}'); end if;
    select * into t from public.event_valet_tickets where id = (b->>'ticketId')::uuid and event_id = ev.id for update;
    if not found then perform public._ev_err('NOT_FOUND'); end if;
    if t.status = 'DELIVERED' then perform public._ev_err('BAD_INPUT', '{"why":"already_delivered"}'); end if;

    if p_op = 'move-hook' then
      if (b->>'hook') !~ '^\d{1,3}$' then perform public._ev_err('BAD_INPUT', '{"field":"hook"}'); end if;
      v_hook := (b->>'hook')::int;
      if not public._ev_hook_allowed(ev, a.kind, v_hook) then perform public._ev_err('BAD_INPUT', '{"field":"hook","why":"not_your_pool"}'); end if;
      if not public._ev_hook_free(ev, v_hook, v_ck, t.id) then
        perform public._ev_err('HOOK_TAKEN', jsonb_build_object('hook', v_hook, 'suggestedHook', public._ev_alloc(ev, a.kind, v_ck)));
      end if;
      v_from := t.slot_no::text;
      update public.event_valet_tickets set slot_no = v_hook, updated_at = now() where id = t.id returning * into t;
      insert into public.event_valet_audit (event_id, ticket_id, action, detail)
      values (ev.id, t.id, 'MOVE_HOOK', jsonb_build_object('actor', v_actor, 'from', v_from, 'to', v_hook));

    elsif p_op = 'edit' then
      if b ? 'location' and not ((b->>'location') = any (ev.locations)) then perform public._ev_err('BAD_INPUT', '{"field":"location"}'); end if;
      if b ? 'phone' and public.event_valet_normalize_phone(b->>'phone') is null then perform public._ev_err('BAD_INPUT', '{"field":"phone"}'); end if;
      if b ? 'vehicle' and length(public._ev_vehicle_text(b->'vehicle')) not between 1 and 60 then perform public._ev_err('BAD_INPUT', '{"field":"vehicle"}'); end if;
      update public.event_valet_tickets set
        parking_location = case when b ? 'location' then b->>'location' else parking_location end,
        phone_e164       = case when b ? 'phone' then public.event_valet_normalize_phone(b->>'phone') else phone_e164 end,
        vehicle          = case when b ? 'vehicle' then public._ev_vehicle_text(b->'vehicle') else vehicle end,
        vehicle_color    = case when b ? 'vehicle' then nullif(upper(btrim(b#>>'{vehicle,color}')), '') else vehicle_color end,
        vehicle_make     = case when b ? 'vehicle' then nullif(upper(btrim(b#>>'{vehicle,make}')), '') else vehicle_make end,
        vehicle_model    = case when b ? 'vehicle' then nullif(upper(btrim(b#>>'{vehicle,model}')), '') else vehicle_model end,
        vehicle_plate    = case when b ? 'vehicle' then nullif(upper(btrim(b#>>'{vehicle,plate}')), '') else vehicle_plate end,
        updated_at = now()
      where id = t.id returning * into t;
      insert into public.event_valet_audit (event_id, ticket_id, action, detail)
      values (ev.id, t.id, 'EDIT', jsonb_build_object('actor', v_actor, 'fields', (select jsonb_agg(k) from jsonb_object_keys(b - 'clientKey' - 'ticketId') k)));

    else -- status
      v_to := b->>'to'; v_from := t.status;
      if v_to not in ('REQUESTED','RETRIEVING','READY','DELIVERED','PARKED') then perform public._ev_err('BAD_INPUT', '{"field":"to"}'); end if;
      if v_to = 'RETRIEVING' and t.status = 'RETRIEVING' and t.retrieving_session is distinct from s.id then
        perform public._ev_err('TAKEN_BY', jsonb_build_object('by', t.retrieving_by));
      end if;
      if v_to = 'PARKED' and t.status not in ('REQUESTED','RETRIEVING') then perform public._ev_err('BAD_INPUT', '{"why":"cannot_park"}'); end if;
      if v_to = 'REQUESTED' and t.status not in ('PARKED','RETRIEVING') then perform public._ev_err('BAD_INPUT', '{"why":"cannot_request"}'); end if;
      if v_to <> t.status then
        update public.event_valet_tickets set
          status             = v_to,
          requested_at       = case when v_to = 'PARKED' then null
                                    when v_to = 'REQUESTED' and t.status = 'PARKED' then now()
                                    else coalesce(requested_at, now()) end,
          request_source     = case when v_to = 'PARKED' then null
                                    when v_to = 'REQUESTED' and t.status = 'PARKED' then 'STAFF'
                                    else coalesce(request_source, 'STAFF') end,
          retrieving_by      = case when v_to in ('PARKED','REQUESTED') then null when v_to = 'RETRIEVING' or retrieving_by is null then s.employee_name else retrieving_by end,
          retrieving_access  = case when v_to in ('PARKED','REQUESTED') then null when v_to = 'RETRIEVING' or retrieving_access is null then a.id else retrieving_access end,
          retrieving_session = case when v_to in ('PARKED','REQUESTED') then null when v_to = 'RETRIEVING' or retrieving_session is null then s.id else retrieving_session end,
          retrieving_at      = case when v_to in ('PARKED','REQUESTED') then null when v_to = 'RETRIEVING' then now() else coalesce(retrieving_at, now()) end,
          ready_at           = case when v_to = 'READY' then now() when v_to = 'DELIVERED' then ready_at else null end,
          delivered_at       = case when v_to = 'DELIVERED' then now() else null end,
          delivered_by       = case when v_to = 'DELIVERED' then s.employee_name else null end,
          updated_at         = now()
        where id = t.id returning * into t;
        insert into public.event_valet_audit (event_id, ticket_id, action, detail)
        values (ev.id, t.id, 'STATUS', jsonb_build_object('actor', v_actor, 'from', v_from, 'to', v_to, 'source', 'STAFF_API'));
        v_notify := case v_to when 'RETRIEVING' then 'ONWAY' when 'READY' then 'READY' when 'DELIVERED' then 'THANKS' else null end;
      end if;
    end if;
    v_res := jsonb_build_object('ticket', public.event_valet_staff_ticket(t), 'ticketId', t.id)
             || case when v_notify is not null then jsonb_build_object('notify', v_notify) else '{}'::jsonb end;

  elsif p_op = 'cash-tip' then
    if (b->>'amountCents') !~ '^\d{3,5}$' or (b->>'amountCents')::int not between 100 and 50000 then
      perform public._ev_err('BAD_INPUT', '{"field":"amountCents"}');
    end if;
    v_amt := (b->>'amountCents')::int;
    if b->>'ticketId' is not null then
      if (b->>'ticketId') !~ '^[0-9a-f-]{36}$' or not exists (select 1 from public.event_valet_tickets where id = (b->>'ticketId')::uuid and event_id = ev.id) then
        perform public._ev_err('NOT_FOUND', '{"field":"ticketId"}');
      end if;
    end if;
    select * into v_tip from public.event_valet_tips
     where event_id = ev.id and ticket_id is not distinct from (b->>'ticketId')::uuid and amount_cents = v_amt
       and created_at > now() - interval '3 minutes' order by created_at desc limit 1;
    if found and not coalesce((b->>'confirmDuplicate')::boolean, false) then
      perform public._ev_err('DUPLICATE_CASH', jsonb_build_object('existing', jsonb_build_object('id', v_tip.id, 'amountCents', v_tip.amount_cents,
        'createdAt', v_tip.created_at, 'employeeName', v_tip.employee_name)));
    end if;
    insert into public.event_valet_tips (event_id, ticket_id, amount_cents, employee_name, access_id, session_id, client_key)
    values (ev.id, (b->>'ticketId')::uuid, v_amt, s.employee_name, a.id, s.id, v_ck) returning * into v_tip;
    insert into public.event_valet_audit (event_id, ticket_id, action, detail)
    values (ev.id, v_tip.ticket_id, 'CASH_TIP', jsonb_build_object('actor', v_actor, 'tip_id', v_tip.id, 'amount_cents', v_amt));
    v_res := jsonb_build_object('tip', jsonb_build_object('id', v_tip.id, 'amountCents', v_tip.amount_cents, 'ticketId', v_tip.ticket_id,
                                'employeeName', v_tip.employee_name, 'createdAt', v_tip.created_at));
  else
    perform public._ev_err('NOT_FOUND', '{"why":"op"}');
  end if;

  insert into public.event_valet_ops (access_id, client_key, op, result) values (a.id, v_ck, p_op, v_res);
  return v_res;
end $function$
;
commit;

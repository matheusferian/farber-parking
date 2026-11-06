-- Rollback of 20261121: restores the production definitions read 2026-11-06.
begin;
set local lock_timeout = '5s';
CREATE OR REPLACE FUNCTION public.event_valet_checkin(p_event text, p_phone text, p_vehicle text, p_client_key text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ev public.event_valet_events; t public.event_valet_tickets;
        v_phone text; v_vehicle text; v_no int; v_slot int; v_code text; v_n int := 0;
begin
  if not public.event_valet_is_staff() then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  v_phone := public.event_valet_normalize_phone(p_phone);
  if v_phone is null then raise exception 'INVALID_PHONE' using errcode = '22023'; end if;
  v_vehicle := upper(regexp_replace(btrim(coalesce(p_vehicle,'')), '\s+', ' ', 'g'));
  if length(v_vehicle) = 0 or length(v_vehicle) > 60 then raise exception 'INVALID_VEHICLE' using errcode = '22023'; end if;

  select * into ev from public.event_valet_events where id = p_event for update;
  if not found then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if not ev.is_open then raise exception 'EVENT_CLOSED' using errcode = '55000'; end if;

  if p_client_key is not null then
    select * into t from public.event_valet_tickets where event_id = p_event and client_key = p_client_key;
    if found then return jsonb_build_object('created', false, 'ticket', public.event_valet_ticket_json(t)); end if;
  end if;

  select coalesce(max(ticket_no), 0) + 1 into v_no from public.event_valet_tickets where event_id = p_event;
  v_code := right(v_phone, 4);
  while exists (select 1 from public.event_valet_tickets where event_id = p_event and ticket_code = v_code) loop
    v_n := v_n + 1;
    if v_n > 9 then raise exception 'TOO_MANY_TICKETS_FOR_PHONE' using errcode = '54000'; end if;
    v_code := v_n::text || right(v_phone, 4);   -- 10101, 20101, …
  end loop;
  select s into v_slot from generate_series(1, ev.slot_capacity) s
   where not exists (select 1 from public.event_valet_tickets x
                      where x.event_id = p_event and x.slot_no = s and x.status <> 'DELIVERED')
   order by s limit 1;

  insert into public.event_valet_tickets (event_id, ticket_no, ticket_code, slot_no, phone_e164, vehicle, client_key)
  values (p_event, v_no, v_code, v_slot, v_phone, v_vehicle, p_client_key)
  returning * into t;
  insert into public.event_valet_audit (event_id, ticket_id, action, detail)
  values (p_event, t.id, 'CHECK_IN', jsonb_build_object('ticket_no', v_no, 'ticket_code', v_code, 'slot_no', v_slot));
  return jsonb_build_object('created', true, 'slots_full', v_slot is null, 'ticket', public.event_valet_ticket_json(t));
end $function$
;

CREATE OR REPLACE FUNCTION public.event_valet_checkin_offline(p_event text, p_phone text, p_vehicle text, p_client_key text, p_code_hint text, p_slot_hint integer, p_location text, p_checked_in_at timestamp with time zone, p_printed boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare ev public.event_valet_events; t public.event_valet_tickets;
        v_phone text; v_vehicle text; v_no int; v_slot int; v_code text; v_n int := 0; v_at timestamptz; v_loc text;
begin
  if not public.event_valet_is_staff() then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if coalesce(p_client_key, '') = '' then raise exception 'CLIENT_KEY_REQUIRED' using errcode = '22023'; end if;
  v_phone := public.event_valet_normalize_phone(p_phone);
  if v_phone is null then raise exception 'INVALID_PHONE' using errcode = '22023'; end if;
  v_vehicle := upper(regexp_replace(btrim(coalesce(p_vehicle,'')), '\s+', ' ', 'g'));
  if length(v_vehicle) = 0 or length(v_vehicle) > 60 then raise exception 'INVALID_VEHICLE' using errcode = '22023'; end if;
  select * into ev from public.event_valet_events where id = p_event for update;
  if not found then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  v_loc := case when p_location = any(ev.locations) then p_location else null end;  -- per-event list

  -- retry of the same offline check-in → same ticket
  select * into t from public.event_valet_tickets where event_id = p_event and client_key = p_client_key;
  if found then
    if t.parking_location is null and v_loc is not null then
      update public.event_valet_tickets set parking_location = v_loc, updated_at = now() where id = t.id returning * into t;
    end if;
    if coalesce(p_printed, false) and t.print_count = 0 then
      update public.event_valet_tickets set print_count = 1, last_printed_at = now() where id = t.id returning * into t;
    end if;
    return jsonb_build_object('created', false, 'code_changed', t.ticket_code is distinct from p_code_hint,
      'slot_changed', t.slot_no is distinct from p_slot_hint, 'ticket', public.event_valet_ticket_json(t));
  end if;

  select coalesce(max(ticket_no), 0) + 1 into v_no from public.event_valet_tickets where event_id = p_event;

  -- code: keep the printed one when it is valid for this phone and still free
  if p_code_hint ~ '^[0-9]{4,5}$' and right(p_code_hint, 4) = right(v_phone, 4)
     and not exists (select 1 from public.event_valet_tickets where event_id = p_event and ticket_code = p_code_hint) then
    v_code := p_code_hint;
  else
    v_code := right(v_phone, 4);
    while exists (select 1 from public.event_valet_tickets where event_id = p_event and ticket_code = v_code) loop
      v_n := v_n + 1;
      if v_n > 9 then raise exception 'TOO_MANY_TICKETS_FOR_PHONE' using errcode = '54000'; end if;
      v_code := v_n::text || right(v_phone, 4);
    end loop;
  end if;

  -- slot: keep the printed one when still free
  if p_slot_hint between 1 and ev.slot_capacity and not exists (select 1 from public.event_valet_tickets x
       where x.event_id = p_event and x.slot_no = p_slot_hint and x.status <> 'DELIVERED') then
    v_slot := p_slot_hint;
  else
    select s into v_slot from generate_series(1, ev.slot_capacity) s
     where not exists (select 1 from public.event_valet_tickets x
                        where x.event_id = p_event and x.slot_no = s and x.status <> 'DELIVERED')
     order by s limit 1;
  end if;

  v_at := coalesce(p_checked_in_at, now());
  if v_at > now() or v_at < now() - interval '12 hours' then v_at := now(); end if;

  insert into public.event_valet_tickets (event_id, ticket_no, ticket_code, slot_no, phone_e164, vehicle, client_key,
                                          checked_in_at, parking_location, print_count, last_printed_at)
  values (p_event, v_no, v_code, v_slot, v_phone, v_vehicle, p_client_key, v_at, v_loc,
          case when coalesce(p_printed, false) then 1 else 0 end, case when coalesce(p_printed, false) then now() end)
  returning * into t;
  insert into public.event_valet_audit (event_id, ticket_id, action, detail)
  values (p_event, t.id, 'CHECK_IN', jsonb_build_object('offline', true, 'ticket_no', v_no, 'ticket_code', v_code, 'slot_no', v_slot,
          'code_hint', p_code_hint, 'slot_hint', p_slot_hint));
  return jsonb_build_object('created', true, 'code_changed', v_code is distinct from p_code_hint,
    'slot_changed', v_slot is distinct from p_slot_hint, 'slots_full', v_slot is null, 'ticket', public.event_valet_ticket_json(t));
end $function$
;

CREATE OR REPLACE FUNCTION public.event_valet_set_slot(p_ticket uuid, p_slot integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t public.event_valet_tickets; ev public.event_valet_events; v_old int;
begin
  if not public.event_valet_is_staff() then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into t from public.event_valet_tickets where id = p_ticket;
  if not found then raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002'; end if;
  select * into ev from public.event_valet_events where id = t.event_id for update;
  select * into t from public.event_valet_tickets where id = p_ticket for update;
  if t.status = 'DELIVERED' then raise exception 'ALREADY_DELIVERED' using errcode = '55000'; end if;
  if p_slot is null or p_slot < 1 or p_slot > ev.slot_capacity then raise exception 'INVALID_SLOT' using errcode = '22023'; end if;
  if exists (select 1 from public.event_valet_tickets x where x.event_id = t.event_id
             and x.slot_no = p_slot and x.status <> 'DELIVERED' and x.id <> t.id) then
    raise exception 'SLOT_OCCUPIED' using errcode = '23505';
  end if;
  v_old := t.slot_no;
  if v_old is not distinct from p_slot then
    return jsonb_build_object('changed', false, 'ticket', public.event_valet_ticket_json(t));
  end if;
  update public.event_valet_tickets set slot_no = p_slot, updated_at = now() where id = p_ticket returning * into t;
  insert into public.event_valet_audit (event_id, ticket_id, action, detail)
  values (t.event_id, t.id, 'SLOT_CHANGE', jsonb_build_object('from', v_old, 'to', p_slot));
  return jsonb_build_object('changed', true, 'ticket', public.event_valet_ticket_json(t));
end $function$
;

CREATE OR REPLACE FUNCTION public.event_valet_delete_ticket(p_ticket uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t public.event_valet_tickets; ev public.event_valet_events; v_msgs int;
begin
  if not public.event_valet_is_staff() then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into t from public.event_valet_tickets where id = p_ticket;
  if not found then return jsonb_build_object('deleted', false); end if;
  select * into ev from public.event_valet_events where id = t.event_id for update;
  delete from public.event_valet_messages where ticket_id = p_ticket;
  get diagnostics v_msgs = row_count;
  delete from public.event_valet_tickets where id = p_ticket;
  insert into public.event_valet_audit (event_id, ticket_id, action, detail)
  values (t.event_id, t.id, 'DELETE', public.event_valet_ticket_json(t) || jsonb_build_object('messages_deleted', v_msgs));
  return jsonb_build_object('deleted', true, 'ticket_code', t.ticket_code);
end $function$
;

CREATE OR REPLACE FUNCTION public.event_valet_set_location(p_ticket uuid, p_location text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t public.event_valet_tickets; v_old text;
begin
  if not public.event_valet_is_staff() then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into t from public.event_valet_tickets where id = p_ticket for update;
  if not found then raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002'; end if;
  if p_location is null or not exists (select 1 from public.event_valet_events e
                                        where e.id = t.event_id and p_location = any(e.locations)) then
    raise exception 'INVALID_LOCATION' using errcode = '22023';
  end if;
  v_old := t.parking_location;
  if v_old is not distinct from p_location then
    return jsonb_build_object('changed', false, 'first', false, 'ticket', public.event_valet_ticket_json(t));
  end if;
  update public.event_valet_tickets set parking_location = p_location, updated_at = now()
   where id = p_ticket returning * into t;
  insert into public.event_valet_audit (event_id, ticket_id, action, detail)
  values (t.event_id, t.id, 'LOCATION', jsonb_build_object('from', v_old, 'to', p_location));
  return jsonb_build_object('changed', true, 'first', v_old is null, 'ticket', public.event_valet_ticket_json(t));
end $function$
;
commit;

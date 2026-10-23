-- Rollback of 20261024_event_valet_numeric_codes.sql (only valid while no 5-digit code exists)
begin;
alter table public.event_valet_tickets drop constraint event_valet_tickets_ticket_code_check;
alter table public.event_valet_tickets add constraint event_valet_tickets_ticket_code_check
  check (ticket_code ~ '^[0-9]{4}(-[B-Z])?$');
create or replace function public.event_valet_checkin(
  p_event text, p_phone text, p_vehicle text, p_client_key text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
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

  -- Double-tap / retry: same client_key returns the ticket already created.
  if p_client_key is not null then
    select * into t from public.event_valet_tickets where event_id = p_event and client_key = p_client_key;
    if found then return jsonb_build_object('created', false, 'ticket', public.event_valet_ticket_json(t)); end if;
  end if;

  select coalesce(max(ticket_no), 0) + 1 into v_no from public.event_valet_tickets where event_id = p_event;
  v_code := right(v_phone, 4);
  while exists (select 1 from public.event_valet_tickets where event_id = p_event and ticket_code = v_code) loop
    v_n := v_n + 1;
    if v_n > 24 then raise exception 'TOO_MANY_TICKETS_FOR_PHONE' using errcode = '54000'; end if;
    v_code := right(v_phone, 4) || '-' || chr(65 + v_n);   -- -B, -C, …
  end loop;
  select s into v_slot from generate_series(1, ev.slot_capacity) s
   where not exists (select 1 from public.event_valet_tickets x
                      where x.event_id = p_event and x.slot_no = s and x.status <> 'DELIVERED')
   order by s limit 1;  -- NULL when every slot is taken (operator assigns manually)

  insert into public.event_valet_tickets (event_id, ticket_no, ticket_code, slot_no, phone_e164, vehicle, client_key)
  values (p_event, v_no, v_code, v_slot, v_phone, v_vehicle, p_client_key)
  returning * into t;
  insert into public.event_valet_audit (event_id, ticket_id, action, detail)
  values (p_event, t.id, 'CHECK_IN', jsonb_build_object('ticket_no', v_no, 'ticket_code', v_code, 'slot_no', v_slot));
  return jsonb_build_object('created', true, 'slots_full', v_slot is null, 'ticket', public.event_valet_ticket_json(t));
end $$;

commit;

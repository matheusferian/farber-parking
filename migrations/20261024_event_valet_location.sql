-- Event Valet: parking location (owner request 2026-10-23).
-- Valet picks it AFTER parking: HANGAR 19 / HANGAR 18 / GRASS / FENCE.
-- The key ticket prints only once a location is set (page logic).
-- Only event_valet_* touched. Rollback: 20261024_event_valet_location_rollback.sql
begin;

alter table public.event_valet_tickets add column parking_location text
  check (parking_location in ('HANGAR 19','HANGAR 18','GRASS','FENCE'));

create or replace function public.event_valet_ticket_json(t public.event_valet_tickets)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'event_id', t.event_id, 'ticket_no', t.ticket_no, 'ticket_code', t.ticket_code, 'slot_no', t.slot_no,
    'phone_e164', t.phone_e164, 'vehicle', t.vehicle, 'status', t.status,
    'checked_in_at', t.checked_in_at, 'requested_at', t.requested_at,
    'request_source', t.request_source, 'ready_at', t.ready_at,
    'delivered_at', t.delivered_at, 'print_count', t.print_count,
    'last_printed_at', t.last_printed_at, 'parking_location', t.parking_location);
$$;

create or replace function public.event_valet_set_location(p_ticket uuid, p_location text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.event_valet_tickets; v_old text;
begin
  if not public.event_valet_is_staff() then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if p_location is null or p_location not in ('HANGAR 19','HANGAR 18','GRASS','FENCE') then
    raise exception 'INVALID_LOCATION' using errcode = '22023';
  end if;
  select * into t from public.event_valet_tickets where id = p_ticket for update;
  if not found then raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002'; end if;
  v_old := t.parking_location;
  if v_old is not distinct from p_location then
    return jsonb_build_object('changed', false, 'first', false, 'ticket', public.event_valet_ticket_json(t));
  end if;
  update public.event_valet_tickets set parking_location = p_location, updated_at = now()
   where id = p_ticket returning * into t;
  insert into public.event_valet_audit (event_id, ticket_id, action, detail)
  values (t.event_id, t.id, 'LOCATION', jsonb_build_object('from', v_old, 'to', p_location));
  return jsonb_build_object('changed', true, 'first', v_old is null, 'ticket', public.event_valet_ticket_json(t));
end $$;

revoke all on function public.event_valet_set_location(uuid, text) from public, anon;
grant execute on function public.event_valet_set_location(uuid, text) to authenticated;

commit;

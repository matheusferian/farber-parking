-- Rollback of 20261024_event_valet_location.sql
begin;
drop function if exists public.event_valet_set_location(uuid, text);
create or replace function public.event_valet_ticket_json(t public.event_valet_tickets)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'event_id', t.event_id, 'ticket_no', t.ticket_no, 'ticket_code', t.ticket_code, 'slot_no', t.slot_no,
    'phone_e164', t.phone_e164, 'vehicle', t.vehicle, 'status', t.status,
    'checked_in_at', t.checked_in_at, 'requested_at', t.requested_at,
    'request_source', t.request_source, 'ready_at', t.ready_at,
    'delivered_at', t.delivered_at, 'print_count', t.print_count,
    'last_printed_at', t.last_printed_at);
$$;
alter table public.event_valet_tickets drop column if exists parking_location;
commit;

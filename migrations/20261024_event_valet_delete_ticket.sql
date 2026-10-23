-- Event Valet: operator can delete a mistaken/test ticket (owner request 2026-10-23).
-- Frees its key slot; a snapshot of the ticket stays in event_valet_audit.
-- Rollback: 20261024_event_valet_delete_ticket_rollback.sql
begin;

create or replace function public.event_valet_delete_ticket(p_ticket uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
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
end $$;

revoke all on function public.event_valet_delete_ticket(uuid) from public, anon;
grant execute on function public.event_valet_delete_ticket(uuid) to authenticated;

commit;

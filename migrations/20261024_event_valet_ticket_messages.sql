-- Event Valet: text-message history of one ticket, for the SMS preview in the
-- staff "View details" sheet (owner request 2026-10-23). Read-only; loaded only
-- when the sheet opens, so the 3-second board poll stays small.
-- Only event_valet_* touched. Rollback: 20261024_event_valet_ticket_messages_rollback.sql
begin;

create or replace function public.event_valet_ticket_messages(p_ticket uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.event_valet_is_staff() then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('dir', m.direction, 'kind', m.kind, 'status', m.status,
            'error_code', m.error_code, 'body', left(m.body, 700), 'at', m.created_at) order by m.created_at, m.id)
          from public.event_valet_messages m where m.ticket_id = p_ticket), '[]'::jsonb);
end $$;

revoke all on function public.event_valet_ticket_messages(uuid) from public, anon;
grant execute on function public.event_valet_ticket_messages(uuid) to authenticated;

commit;

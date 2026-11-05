-- Rollback of 20261113_event_valet_guest_tokens.sql: original functions (as in 20261024) back, table removed.
begin;
CREATE OR REPLACE FUNCTION public.event_valet_mint_guest_token(p_ticket uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare v_tok text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  update public.event_valet_tickets set guest_token_hash = sha256(convert_to(v_tok, 'UTF8'))
   where id = p_ticket;
  if not found then raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002'; end if;
  return v_tok;
end $$

;
CREATE OR REPLACE FUNCTION public.event_valet_guest(p_token text, p_action text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare t public.event_valet_tickets; ev public.event_valet_events; r jsonb; v_changed boolean := false;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return jsonb_build_object('state', 'invalid'); end if;
  select * into t from public.event_valet_tickets where guest_token_hash = sha256(convert_to(p_token, 'UTF8'));
  if not found then return jsonb_build_object('state', 'invalid'); end if;
  select * into ev from public.event_valet_events where id = t.event_id;
  if p_action = 'request' then
    if t.status = 'PARKED' then
      r := public.event_valet_apply_status(t.id, 'REQUESTED', 'GUEST_LINK');
      v_changed := (r->>'changed')::boolean;
      select * into t from public.event_valet_tickets where id = t.id;
    end if;
  end if;
  return jsonb_build_object('state', 'ok', 'changed', v_changed, 'ticket_id', t.id,
    'title', ev.title, 'event_date', ev.event_date, 'ticket_no', t.ticket_no, 'ticket_code', t.ticket_code,
    'vehicle', t.vehicle, 'status', t.status,
    'tip_links', case when ev.tip_enabled and t.status = 'DELIVERED' then ev.tip_links else null end);
end $$

;
drop table if exists public.event_valet_guest_tokens;
revoke all on function public.event_valet_mint_guest_token(uuid) from public, anon, authenticated;
revoke all on function public.event_valet_guest(text, text) from public, anon, authenticated;
grant execute on function public.event_valet_mint_guest_token(uuid) to service_role;
grant execute on function public.event_valet_guest(text, text) to service_role;
commit;

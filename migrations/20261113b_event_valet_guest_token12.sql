-- Watermakers hotfix #2 (owner 2026-11-05: "muito grande o link ainda"):
--   * pass tokens for events with a Revenue slug are now 12 base64url chars (72 random
--     bits; the 2-day pass is tied to one car, tokens are stored hashed);
--   * 64-hex (Halloween) and 22-char tokens already sent keep working;
--   * the 2-day-after-delivery expiry from 13a is unchanged.
-- Halloween (no revenue_slug) keeps its 64-hex tokens and never expires (unchanged).
-- Only the two functions below are replaced; no table, grant or other object changes.
begin;

create or replace function public.event_valet_mint_guest_token(p_ticket uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_tok text; v_old bytea; v_keep boolean;
begin
  select t.guest_token_hash, e.revenue_slug is not null into v_old, v_keep
    from public.event_valet_tickets t join public.event_valet_events e on e.id = t.event_id
   where t.id = p_ticket for update of t;
  if not found then raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002'; end if;
  v_tok := case when v_keep
    then rtrim(translate(encode(extensions.gen_random_bytes(9), 'base64'), '+/', '-_'), '=')
    else replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '') end;
  if v_keep and v_old is not null then
    insert into public.event_valet_guest_tokens (token_hash, ticket_id) values (v_old, p_ticket) on conflict do nothing;
  end if;
  update public.event_valet_tickets set guest_token_hash = sha256(convert_to(v_tok, 'UTF8'))
   where id = p_ticket;
  return v_tok;
end $$;

create or replace function public.event_valet_guest(p_token text, p_action text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.event_valet_tickets; ev public.event_valet_events; r jsonb; v_changed boolean := false;
begin
  if p_token is null or p_token !~ '^([0-9a-f]{64}|[A-Za-z0-9_-]{22}|[A-Za-z0-9_-]{12})$' then return jsonb_build_object('state', 'invalid'); end if;
  select * into t from public.event_valet_tickets where guest_token_hash = sha256(convert_to(p_token, 'UTF8'));
  if not found then
    -- an earlier link of the same ticket (kept by mint for Watermakers), only while the event is open
    select x.* into t from public.event_valet_guest_tokens g
      join public.event_valet_tickets x on x.id = g.ticket_id
      join public.event_valet_events e on e.id = x.event_id
     where g.token_hash = sha256(convert_to(p_token, 'UTF8')) and e.is_open and e.closed_at is null;
    if not found then return jsonb_build_object('state', 'invalid'); end if;
  end if;
  select * into ev from public.event_valet_events where id = t.event_id;
  -- Watermakers: the thank-you page stays 2 days after delivery, then the link expires.
  if ev.revenue_slug is not null and t.status = 'DELIVERED' and t.delivered_at < now() - interval '2 days' then
    return jsonb_build_object('state', 'expired');
  end if;
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
end $$;

revoke all on function public.event_valet_mint_guest_token(uuid) from public, anon, authenticated;
revoke all on function public.event_valet_guest(text, text) from public, anon, authenticated;
grant execute on function public.event_valet_mint_guest_token(uuid) to service_role;
grant execute on function public.event_valet_guest(text, text) to service_role;
commit;

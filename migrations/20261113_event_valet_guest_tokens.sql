-- Event Valet: a Watermakers ticket keeps every pass link it was ever sent
-- (owner bug report 2026-11-05: the thank-you text minted a new token and the
-- welcome link stopped working). Earlier links stay valid until the event closes;
-- the newest link keeps working exactly as before. Only for events whose pass
-- lives on after delivery (revenue_slug set = Watermakers). Halloween is unchanged:
-- a new link still replaces the old one there.
-- Rollback: 20261113_event_valet_guest_tokens_rollback.sql
begin;

create table public.event_valet_guest_tokens (
  token_hash bytea primary key,
  ticket_id  uuid not null references public.event_valet_tickets(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index event_valet_guest_tokens_ticket on public.event_valet_guest_tokens (ticket_id);
alter table public.event_valet_guest_tokens enable row level security;
grant all on public.event_valet_guest_tokens to service_role;

create or replace function public.event_valet_mint_guest_token(p_ticket uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_tok text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''); v_old bytea; v_keep boolean;
begin
  select t.guest_token_hash, e.revenue_slug is not null into v_old, v_keep
    from public.event_valet_tickets t join public.event_valet_events e on e.id = t.event_id
   where t.id = p_ticket for update of t;
  if not found then raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002'; end if;
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
  if p_token is null or p_token !~ '^[0-9a-f]{64}$' then return jsonb_build_object('state', 'invalid'); end if;
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

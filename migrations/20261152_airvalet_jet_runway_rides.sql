-- Jet Runway Café rides (owner 2026-11-11, mockups approved): staff drop a guest at Jet Runway Café,
-- type ONLY the phone number; the guest replies READY for the ride back; staff tap On my way / Done;
-- Done texts a tip link that works for 1 day (Matt Solutions Stripe, via the `ride` Edge Function).
-- No names, no car, no passenger record. Tables are reachable only through the functions below.
-- Rollback: 20261152_airvalet_jet_runway_rides_rollback.sql

create table if not exists public.airvalet_rides (
  id              uuid primary key default gen_random_uuid(),
  phone_e164      text not null check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  status          text not null default 'WAITING' check (status in ('WAITING','READY','ONWAY','DONE','CANCELLED')),
  client_key      text unique,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  created_by_name text,
  ready_at        timestamptz,
  onway_at        timestamptz,
  onway_by_name   text,
  done_at         timestamptz,
  done_by_name    text,
  tip_token_hash  text unique,
  tip_expires_at  timestamptz
);
-- One open ride per phone at a time.
create unique index if not exists airvalet_rides_one_open on public.airvalet_rides (phone_e164)
  where status in ('WAITING','READY','ONWAY');
create index if not exists airvalet_rides_created on public.airvalet_rides (created_at desc);

create table if not exists public.airvalet_ride_messages (
  id          bigserial primary key,
  ride_id     uuid not null references public.airvalet_rides(id) on delete cascade,
  kind        text not null check (kind in ('START','ONWAY','DONE','READY_IN')),
  body        text,
  sid         text,
  status      text not null,
  error_code  text,
  created_at  timestamptz not null default now()
);
create index if not exists airvalet_ride_messages_ride on public.airvalet_ride_messages (ride_id);

alter table public.airvalet_rides enable row level security;
alter table public.airvalet_ride_messages enable row level security;
revoke all on public.airvalet_rides from anon, authenticated;
revoke all on public.airvalet_ride_messages from anon, authenticated;

-- ── staff: create (idempotent by client key; an open ride for the same phone is returned as is) ──
create or replace function public.airvalet_ride_create(p_phone text, p_client_key text, p_name text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.airvalet_rides;
begin
  if auth.uid() is null or public.current_user_role() is null
     or not (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[])) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_phone is null or p_phone !~ '^\+[1-9][0-9]{7,14}$' then return jsonb_build_object('result', 'BAD_PHONE'); end if;
  if p_client_key is not null then
    select * into r from public.airvalet_rides where client_key = p_client_key;
    if found then return jsonb_build_object('result', 'OK', 'id', r.id, 'status', r.status, 'existing', true, 'sent', true); end if;
  end if;
  select * into r from public.airvalet_rides where phone_e164 = p_phone and status in ('WAITING','READY','ONWAY');
  if found then return jsonb_build_object('result', 'OPEN', 'id', r.id, 'status', r.status, 'existing', true); end if;
  insert into public.airvalet_rides (phone_e164, client_key, created_by, created_by_name)
    values (p_phone, nullif(p_client_key, ''), auth.uid(), left(nullif(trim(p_name), ''), 40))
    returning * into r;
  return jsonb_build_object('result', 'OK', 'id', r.id, 'status', r.status, 'existing', false, 'phone', r.phone_e164);
end $$;

-- ── staff: On my way / Done / Cancel. Done mints the 1-day tip token (returned once, stored hashed). ──
create or replace function public.airvalet_ride_set(p_id uuid, p_status text, p_name text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.airvalet_rides; v_tok text;
begin
  if auth.uid() is null or public.current_user_role() is null
     or not (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[])) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into r from public.airvalet_rides where id = p_id for update;
  if not found then return jsonb_build_object('result', 'NOT_FOUND'); end if;
  if p_status = 'ONWAY' then
    if r.status = 'ONWAY' then return jsonb_build_object('result', 'SAME', 'id', r.id, 'status', r.status); end if;
    if r.status not in ('WAITING','READY') then return jsonb_build_object('result', 'CLOSED', 'id', r.id, 'status', r.status); end if;
    update public.airvalet_rides set status = 'ONWAY', onway_at = now(), onway_by_name = left(nullif(trim(p_name), ''), 40)
      where id = p_id returning * into r;
    return jsonb_build_object('result', 'OK', 'id', r.id, 'status', r.status, 'phone', r.phone_e164);
  elsif p_status = 'DONE' then
    if r.status = 'DONE' then return jsonb_build_object('result', 'SAME', 'id', r.id, 'status', r.status); end if;
    if r.status = 'CANCELLED' then return jsonb_build_object('result', 'CLOSED', 'id', r.id, 'status', r.status); end if;
    v_tok := translate(encode(extensions.gen_random_bytes(12), 'base64'), '+/', '-_');
    update public.airvalet_rides set status = 'DONE', done_at = now(), done_by_name = left(nullif(trim(p_name), ''), 40),
        tip_token_hash = encode(extensions.digest(v_tok, 'sha256'), 'hex'), tip_expires_at = now() + interval '1 day'
      where id = p_id returning * into r;
    return jsonb_build_object('result', 'OK', 'id', r.id, 'status', r.status, 'phone', r.phone_e164, 'tip_token', v_tok);
  elsif p_status = 'CANCELLED' then
    if r.status in ('DONE','CANCELLED') then return jsonb_build_object('result', 'SAME', 'id', r.id, 'status', r.status); end if;
    update public.airvalet_rides set status = 'CANCELLED' where id = p_id returning * into r;
    return jsonb_build_object('result', 'OK', 'id', r.id, 'status', r.status);
  end if;
  return jsonb_build_object('result', 'BAD_STATUS');
end $$;

-- ── staff app + TV: today's rides. The TV gets only the last 4 digits. ──
create or replace function public.airvalet_rides_board()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_tv boolean;
begin
  if auth.uid() is null or public.current_user_role() is null
     or not (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER','TV_ONLY']::public.account_role[])) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  v_tv := public.current_user_role() = 'TV_ONLY';
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', r.id, 'status', r.status, 'last4', right(r.phone_e164, 4),
      'phone', case when v_tv then null else r.phone_e164 end,
      'created_at', r.created_at, 'ready_at', r.ready_at, 'onway_at', r.onway_at, 'done_at', r.done_at,
      'onway_by', r.onway_by_name, 'created_by', case when v_tv then null else r.created_by_name end)
      order by case r.status when 'READY' then 0 when 'ONWAY' then 1 when 'WAITING' then 2 else 3 end, r.created_at desc)
    from public.airvalet_rides r
    where r.status in ('WAITING','READY','ONWAY')
       or (r.status = 'DONE' and r.done_at > (date_trunc('day', now() at time zone 'America/New_York') at time zone 'America/New_York'))), '[]'::jsonb);
end $$;

-- ── server only (twilio-inbound): the guest replied READY ──
create or replace function public.airvalet_ride_mark_ready(p_phone text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.airvalet_rides;
begin
  select * into r from public.airvalet_rides
    where phone_e164 = p_phone and status in ('WAITING','READY','ONWAY') and created_at > now() - interval '18 hours'
    for update;
  if not found then return jsonb_build_object('result', 'NONE'); end if;
  if r.status = 'WAITING' then
    update public.airvalet_rides set status = 'READY', ready_at = now() where id = r.id returning * into r;
    return jsonb_build_object('result', 'READY', 'id', r.id, 'last4', right(r.phone_e164, 4), 'new', true);
  end if;
  return jsonb_build_object('result', 'READY', 'id', r.id, 'last4', right(r.phone_e164, 4), 'new', false, 'status', r.status);
end $$;

-- ── server only (`ride` function): the 1-day tip link ──
create or replace function public.airvalet_ride_tip_claim(p_token text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r public.airvalet_rides;
begin
  if p_token is null or length(p_token) < 12 or length(p_token) > 64 then return jsonb_build_object('state', 'invalid'); end if;
  select * into r from public.airvalet_rides where tip_token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex');
  if not found then return jsonb_build_object('state', 'invalid'); end if;
  if r.tip_expires_at is null or r.tip_expires_at < now() then return jsonb_build_object('state', 'expired'); end if;
  return jsonb_build_object('state', 'ok', 'ride_id', r.id, 'expires_at', r.tip_expires_at);
end $$;

revoke all on function public.airvalet_ride_create(text, text, text) from public, anon;
revoke all on function public.airvalet_ride_set(uuid, text, text) from public, anon;
revoke all on function public.airvalet_rides_board() from public, anon;
revoke all on function public.airvalet_ride_mark_ready(text) from public, anon, authenticated;
revoke all on function public.airvalet_ride_tip_claim(text) from public, anon, authenticated;
grant execute on function public.airvalet_ride_create(text, text, text) to authenticated;
grant execute on function public.airvalet_ride_set(uuid, text, text) to authenticated;
grant execute on function public.airvalet_rides_board() to authenticated;
grant execute on function public.airvalet_ride_mark_ready(text) to service_role;
grant execute on function public.airvalet_ride_tip_claim(text) to service_role;

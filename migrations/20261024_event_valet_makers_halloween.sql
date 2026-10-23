-- Event Valet (temporary module) — MAKERS AIR HALLOWEEN VALET, 2026-10-24
--
-- Free valet for staff and guests at Makers Air (FXE), ~10-15 cars.
-- Fully separate from the normal AirValet operation:
--   * new tables only (event_valet_*); passengers / activity_log /
--     daily_closing_reports / payments / SMS tables are NOT touched;
--   * no existing function, view, trigger, policy or grant is changed;
--   * no parking charge anywhere; tips are an optional link (Matt Solutions).
--
-- Access model:
--   * tables: RLS on, no policies, no grants for anon/authenticated
--     (deny-all). Everything goes through the functions below.
--   * staff functions (SECURITY DEFINER) check current_user_role() in
--     ADMIN / IPAD_OPS / IPHONE_OPS / MANAGER — same fail-closed set as
--     passengers (20260901_fail_closed_role_checks.sql). TV_ONLY denied.
--   * service functions (inbound SMS, guest link, SMS log) are executable
--     by service_role only (Edge Function event-valet).
--
-- Concurrency: every ticket-number / key-slot allocation locks the event
-- row (SELECT … FOR UPDATE), so two check-ins can never get the same
-- ticket number or slot. A partial unique index is the second guard.
--
-- Rollback: 20261024_event_valet_makers_halloween_rollback.sql (archives
-- the data into schema airvalet_archive, then drops only these objects).

begin;

-- ── Tables ────────────────────────────────────────────────────────────
create table public.event_valet_events (
  id                  text primary key,
  title               text not null,
  event_date          date not null,
  timezone            text not null default 'America/New_York',
  slot_capacity       int  not null default 20 check (slot_capacity between 1 and 200),
  is_open             boolean not null default true,
  -- SMS safety switches: start OFF + test-only. Turned on explicitly.
  sms_enabled         boolean not null default false,
  sms_test_only       boolean not null default true,
  sms_test_phones     text[]  not null default '{}',
  include_ticket_link boolean not null default true,
  -- Optional tips (Stripe Matt Solutions only). OFF until the account is confirmed.
  tip_enabled         boolean not null default false,
  tip_links           jsonb   not null default '{}'::jsonb,
  created_at          timestamptz not null default now()
);

create table public.event_valet_tickets (
  id               uuid primary key default gen_random_uuid(),
  event_id         text not null references public.event_valet_events(id),
  ticket_no        int  not null check (ticket_no > 0),
  -- What the guest and the valet use: last 4 digits of the phone ("0101").
  -- A second car / second visit from the same last 4 gets "0101-B", "0101-C"…
  -- Unique for the whole event, never reused. ticket_no stays as the
  -- internal sequential reference (#001, #002…).
  ticket_code      text not null check (ticket_code ~ '^[0-9]{4}(-[B-Z])?$'),
  slot_no          int  check (slot_no > 0),
  phone_e164       text not null check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  vehicle          text not null check (length(btrim(vehicle)) between 1 and 60),
  status           text not null default 'PARKED'
                   check (status in ('PARKED','REQUESTED','READY','DELIVERED')),
  client_key       text,
  checked_in_at    timestamptz not null default now(),
  requested_at     timestamptz,
  request_source   text,
  ready_at         timestamptz,
  delivered_at     timestamptz,
  print_count      int not null default 0,
  last_printed_at  timestamptz,
  guest_token_hash bytea unique,
  created_by       uuid default auth.uid(),
  updated_at       timestamptz not null default now(),
  unique (event_id, ticket_no),
  unique (event_id, ticket_code),
  unique (event_id, client_key)
);
-- A slot is held only while the car is not delivered. slot_no stays on the
-- delivered row as history; the slot becomes free for the next car.
create unique index event_valet_tickets_active_slot
  on public.event_valet_tickets (event_id, slot_no)
  where status <> 'DELIVERED' and slot_no is not null;
create index event_valet_tickets_phone on public.event_valet_tickets (event_id, phone_e164);

create table public.event_valet_messages (
  id            bigint generated always as identity primary key,
  event_id      text not null references public.event_valet_events(id),
  ticket_id     uuid references public.event_valet_tickets(id),
  direction     text not null check (direction in ('OUT','IN')),
  kind          text not null,
  phone_e164    text,
  body          text,
  twilio_sid    text unique,
  status        text not null,
  error_code    text,
  error_message text,
  dedupe_key    text unique,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index event_valet_messages_ticket on public.event_valet_messages (ticket_id, created_at desc);

create table public.event_valet_audit (
  id        bigint generated always as identity primary key,
  event_id  text not null,
  ticket_id uuid,
  action    text not null,
  detail    jsonb not null default '{}'::jsonb,
  actor     uuid default auth.uid(),
  at        timestamptz not null default now()
);

alter table public.event_valet_events   enable row level security;
alter table public.event_valet_tickets  enable row level security;
alter table public.event_valet_messages enable row level security;
alter table public.event_valet_audit    enable row level security;
revoke all on public.event_valet_events, public.event_valet_tickets,
              public.event_valet_messages, public.event_valet_audit
  from public, anon, authenticated;

insert into public.event_valet_events (id, title, event_date)
values ('makers-halloween-2026', 'MAKERS AIR — HALLOWEEN VALET', date '2026-10-24');

-- ── Helpers ───────────────────────────────────────────────────────────
create or replace function public.event_valet_is_staff()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.current_user_role() = any
    (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]), false);
$$;

-- Same E.164 rules as utils.js normalizePhoneE164 / _shared/sms/phone.ts.
create or replace function public.event_valet_normalize_phone(p_raw text)
returns text language plpgsql immutable set search_path = public as $$
declare d text := regexp_replace(coalesce(p_raw,''), '\D', '', 'g'); e text;
begin
  if btrim(coalesce(p_raw,'')) like '+%' then
    if length(d) between 8 and 15 and left(d,1) <> '0' then return '+' || d; end if;
    return null;
  end if;
  if length(d) = 10 then e := '+1' || d;
  elsif length(d) = 11 and left(d,1) = '1' then e := '+' || d;
  else return null; end if;
  if substr(e,3,1) in ('0','1') or substr(e,6,1) in ('0','1') then return null; end if;
  return e;
end $$;

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

-- ── Staff: check-in ───────────────────────────────────────────────────
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

-- ── Internal status transition (shared by staff, SMS and guest link) ───
create or replace function public.event_valet_apply_status(p_ticket uuid, p_status text, p_source text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.event_valet_tickets; ev public.event_valet_events; v_old text; v_slot int;
begin
  if p_status not in ('PARKED','REQUESTED','READY','DELIVERED') then raise exception 'INVALID_STATUS' using errcode = '22023'; end if;
  select * into t from public.event_valet_tickets where id = p_ticket;
  if not found then raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002'; end if;
  -- lock order: event row first (same as check-in / set_slot), then ticket
  select * into ev from public.event_valet_events where id = t.event_id for update;
  select * into t from public.event_valet_tickets where id = p_ticket for update;
  v_old := t.status;
  if v_old = p_status then
    return jsonb_build_object('changed', false, 'ticket', public.event_valet_ticket_json(t));
  end if;
  if v_old = 'DELIVERED' then
    -- Undo of a mis-tap: staff only, within 15 minutes, back to READY.
    if p_source <> 'STAFF' or p_status <> 'READY' or t.delivered_at < now() - interval '15 minutes' then
      raise exception 'ALREADY_DELIVERED' using errcode = '55000';
    end if;
    v_slot := t.slot_no;
    if v_slot is not null and exists (select 1 from public.event_valet_tickets x
        where x.event_id = t.event_id and x.slot_no = v_slot and x.status <> 'DELIVERED' and x.id <> t.id) then
      v_slot := null;  -- the slot was reused meanwhile: operator reassigns
    end if;
    update public.event_valet_tickets set status = 'READY', delivered_at = null, slot_no = v_slot,
           updated_at = now() where id = p_ticket returning * into t;
  else
    update public.event_valet_tickets set
      status         = p_status,
      requested_at   = case when p_status = 'REQUESTED' then now()
                            when p_status = 'PARKED' then null else requested_at end,
      request_source = case when p_status = 'REQUESTED' then p_source
                            when p_status = 'PARKED' then null else request_source end,
      ready_at       = case when p_status = 'READY' then now()
                            when p_status in ('PARKED','REQUESTED') then null else ready_at end,
      delivered_at   = case when p_status = 'DELIVERED' then now() else null end,
      updated_at     = now()
    where id = p_ticket returning * into t;
  end if;
  insert into public.event_valet_audit (event_id, ticket_id, action, detail)
  values (t.event_id, t.id, 'STATUS', jsonb_build_object('from', v_old, 'to', t.status, 'source', p_source));
  return jsonb_build_object('changed', true, 'from', v_old, 'ticket', public.event_valet_ticket_json(t));
end $$;

create or replace function public.event_valet_set_status(p_ticket uuid, p_status text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public.event_valet_is_staff() then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  return public.event_valet_apply_status(p_ticket, p_status, 'STAFF');
end $$;

-- ── Staff: manual key-slot correction (validated + audited) ──────────
create or replace function public.event_valet_set_slot(p_ticket uuid, p_slot int)
returns jsonb language plpgsql security definer set search_path = public as $$
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
end $$;

-- ── Staff: print bookkeeping (reprint never changes number or slot) ──
create or replace function public.event_valet_mark_printed(p_ticket uuid, p_kind text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.event_valet_tickets;
begin
  if not public.event_valet_is_staff() then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  update public.event_valet_tickets set print_count = print_count + 1, last_printed_at = now()
   where id = p_ticket returning * into t;
  if not found then raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002'; end if;
  insert into public.event_valet_audit (event_id, ticket_id, action, detail)
  values (t.event_id, t.id, 'PRINT', jsonb_build_object('kind', left(coalesce(p_kind,''), 20), 'count', t.print_count));
  return jsonb_build_object('ticket', public.event_valet_ticket_json(t));
end $$;

-- ── Staff: board (tickets + latest SMS per ticket + counters) ────────
create or replace function public.event_valet_board(p_event text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare ev public.event_valet_events;
begin
  if not public.event_valet_is_staff() then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  select * into ev from public.event_valet_events where id = p_event;
  if not found then raise exception 'EVENT_NOT_FOUND' using errcode = 'P0002'; end if;
  return jsonb_build_object(
    'server_time', now(),
    'event', jsonb_build_object('id', ev.id, 'title', ev.title, 'event_date', ev.event_date,
       'timezone', ev.timezone, 'slot_capacity', ev.slot_capacity, 'is_open', ev.is_open,
       'sms_enabled', ev.sms_enabled, 'sms_test_only', ev.sms_test_only, 'tip_enabled', ev.tip_enabled),
    'counts', (select jsonb_build_object(
       'PARKED',    count(*) filter (where status = 'PARKED'),
       'REQUESTED', count(*) filter (where status = 'REQUESTED'),
       'READY',     count(*) filter (where status = 'READY'),
       'DELIVERED', count(*) filter (where status = 'DELIVERED'))
       from public.event_valet_tickets where event_id = p_event),
    'tickets', coalesce((select jsonb_agg(public.event_valet_ticket_json(t) || jsonb_build_object(
         'sms', (select coalesce(jsonb_agg(jsonb_build_object('kind', m.kind, 'status', m.status,
                   'error_code', m.error_code, 'at', m.created_at) order by m.created_at), '[]'::jsonb)
                   from public.event_valet_messages m where m.ticket_id = t.id and m.direction = 'OUT'),
         'last_inbound', (select jsonb_build_object('body', left(m.body, 160), 'at', m.created_at)
                   from public.event_valet_messages m where m.ticket_id = t.id and m.direction = 'IN'
                   order by m.created_at desc limit 1))
       order by t.ticket_no) from public.event_valet_tickets t where t.event_id = p_event), '[]'::jsonb));
end $$;

-- ── Service (Edge Function only) ──────────────────────────────────────
-- Mint (or rotate) the guest link token. The raw token is returned once
-- and only its SHA-256 is stored; a new link invalidates the previous one.
create or replace function public.event_valet_mint_guest_token(p_ticket uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_tok text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  update public.event_valet_tickets set guest_token_hash = sha256(convert_to(v_tok, 'UTF8'))
   where id = p_ticket;
  if not found then raise exception 'TICKET_NOT_FOUND' using errcode = 'P0002'; end if;
  return v_tok;
end $$;

-- Guest page: view / request by token. Never returns slot or phone.
create or replace function public.event_valet_guest(p_token text, p_action text)
returns jsonb language plpgsql security definer set search_path = public as $$
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
end $$;

create or replace function public.event_valet_options(p_ids uuid[])
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('code', t.ticket_code, 'vehicle', t.vehicle) order by t.ticket_no), '[]'::jsonb)
    from public.event_valet_tickets t where t.id = any (p_ids);
$$;

-- Inbound SMS "READY" (optionally with a ticket number). The phone alone
-- is never enough when it has more than one active ticket.
create or replace function public.event_valet_inbound_ready(p_phone text, p_ref text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_active uuid[]; v_match uuid[]; v_id uuid; r jsonb; v_any int; v_ref text;
begin
  select array_agg(t.id order by t.ticket_no) into v_active
    from public.event_valet_tickets t join public.event_valet_events e on e.id = t.event_id
   where e.is_open and t.phone_e164 = p_phone and t.status <> 'DELIVERED';
  if v_active is null then
    select count(*) into v_any from public.event_valet_tickets t join public.event_valet_events e on e.id = t.event_id
     where e.is_open and t.phone_e164 = p_phone;
    return jsonb_build_object('result', case when v_any > 0 then 'DELIVERED' else 'NONE' end);
  end if;
  v_ref := upper(regexp_replace(coalesce(p_ref, ''), '[^0-9A-Za-z]', '', 'g'));
  if v_ref <> '' then
    -- only among THIS phone's active tickets: the phone alone never reaches another car
    select array_agg(t.id) into v_match from public.event_valet_tickets t
     where t.id = any (v_active)
       and (replace(t.ticket_code, '-', '') = v_ref
            or (v_ref ~ '^[0-9]{1,3}$' and t.ticket_no = v_ref::int));
    if v_match is null or array_length(v_match, 1) > 1 then
      return jsonb_build_object('result', case when v_match is null then 'NO_MATCH' else 'AMBIGUOUS' end,
        'options', public.event_valet_options(v_active));
    end if;
    v_id := v_match[1];
  elsif array_length(v_active, 1) > 1 then
    return jsonb_build_object('result', 'AMBIGUOUS', 'options', public.event_valet_options(v_active));
  else
    v_id := v_active[1];
  end if;
  if (select status from public.event_valet_tickets where id = v_id) <> 'PARKED' then
    return jsonb_build_object('result', 'ALREADY', 'ticket',
      (select public.event_valet_ticket_json(t) from public.event_valet_tickets t where t.id = v_id));
  end if;
  r := public.event_valet_apply_status(v_id, 'REQUESTED', 'SMS');
  return jsonb_build_object('result', case when (r->>'changed')::boolean then 'REQUESTED' else 'ALREADY' end,
                            'ticket', r->'ticket');
end $$;

-- ── Grants ────────────────────────────────────────────────────────────
revoke all on function public.event_valet_is_staff()                         from public, anon;
revoke all on function public.event_valet_normalize_phone(text)              from public, anon, authenticated;
revoke all on function public.event_valet_ticket_json(public.event_valet_tickets) from public, anon, authenticated;
revoke all on function public.event_valet_checkin(text, text, text, text)    from public, anon;
revoke all on function public.event_valet_apply_status(uuid, text, text)     from public, anon, authenticated;
revoke all on function public.event_valet_set_status(uuid, text)             from public, anon;
revoke all on function public.event_valet_set_slot(uuid, int)                from public, anon;
revoke all on function public.event_valet_mark_printed(uuid, text)           from public, anon;
revoke all on function public.event_valet_board(text)                        from public, anon;
revoke all on function public.event_valet_mint_guest_token(uuid)             from public, anon, authenticated;
revoke all on function public.event_valet_guest(text, text)                  from public, anon, authenticated;
revoke all on function public.event_valet_inbound_ready(text, text)          from public, anon, authenticated;
revoke all on function public.event_valet_options(uuid[])                    from public, anon, authenticated;

grant execute on function public.event_valet_is_staff()                      to authenticated;
grant execute on function public.event_valet_checkin(text, text, text, text) to authenticated;
grant execute on function public.event_valet_set_status(uuid, text)          to authenticated;
grant execute on function public.event_valet_set_slot(uuid, int)             to authenticated;
grant execute on function public.event_valet_mark_printed(uuid, text)        to authenticated;
grant execute on function public.event_valet_board(text)                     to authenticated;

grant all on public.event_valet_events, public.event_valet_tickets,
             public.event_valet_messages, public.event_valet_audit to service_role;
grant execute on function public.event_valet_normalize_phone(text)          to service_role;
grant execute on function public.event_valet_ticket_json(public.event_valet_tickets) to service_role;
grant execute on function public.event_valet_apply_status(uuid, text, text) to service_role;
grant execute on function public.event_valet_mint_guest_token(uuid)         to service_role;
grant execute on function public.event_valet_guest(text, text)              to service_role;
grant execute on function public.event_valet_inbound_ready(text, text)      to service_role;
grant execute on function public.event_valet_options(uuid[])                to service_role;

commit;

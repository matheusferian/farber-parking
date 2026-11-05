-- Event Valet: Watermakers S710-first operation (contract docs/WATERMAKERS_S710_CONTRACT.md v1).
-- Owner request 2026-11-05. Additive only — every existing function, page and the
-- Halloween event behave exactly as before:
--   * ticket status gains RETRIEVING (only the new staff API produces it);
--   * new columns on events / tickets (defaults keep old rows unchanged);
--   * new tables: access credentials (S710 device + staff links), sessions,
--     idempotent ops, rate counter, hook holds, cash tips;
--   * new service_role-only staff dispatcher  event_valet_staff(token, session, op, body);
--   * new ADMIN-only RPCs (links, flags, report, cash correction, close).
-- Watermakers row: 50 hooks, S710 pool 01–40 / phone pool 41–50, pass link in the
-- welcome SMS, Revenue slug for card tips. Every switch stays OFF.
-- Rollback: 20261112_event_valet_watermakers_s710_rollback.sql
begin;

-- ── events ──────────────────────────────────────────────────────────────
alter table public.event_valet_events
  add column device_pool          int4range not null default '[1,41)',
  add column phone_pool           int4range not null default '[41,51)',
  add column staff_access_enabled boolean   not null default false,
  add column sms_replies_enabled  boolean   not null default false,
  add column thanks_enabled       boolean   not null default false,
  add column revenue_slug         text check (revenue_slug ~ '^[a-z0-9][a-z0-9-]{2,60}$'),
  add column closed_at            timestamptz;

-- ── tickets ─────────────────────────────────────────────────────────────
alter table public.event_valet_tickets drop constraint event_valet_tickets_status_check;
alter table public.event_valet_tickets add constraint event_valet_tickets_status_check
  check (status in ('PARKED','REQUESTED','RETRIEVING','READY','DELIVERED'));
alter table public.event_valet_tickets
  add column vehicle_color      text check (length(vehicle_color) <= 20),
  add column vehicle_make       text check (length(vehicle_make)  <= 30),
  add column vehicle_model      text check (length(vehicle_model) <= 30),
  add column vehicle_plate      text check (length(vehicle_plate) <= 12),
  add column key_stored_at      timestamptz,
  add column offline_checkin    boolean not null default false,
  add column checked_in_by      text,
  add column checked_in_access  uuid,
  add column retrieving_by      text,
  add column retrieving_access  uuid,
  add column retrieving_session uuid,
  add column retrieving_at      timestamptz,
  add column delivered_by       text;

-- ── access credentials (raw token never stored) ─────────────────────────
create table public.event_valet_access (
  id           uuid primary key default gen_random_uuid(),
  event_id     text not null references public.event_valet_events(id),
  kind         text not null check (kind in ('DEVICE','LINK')),
  label        text not null check (length(btrim(label)) between 1 and 40),
  token_hash   bytea not null unique,
  valid_from   timestamptz not null default now(),
  valid_until  timestamptz not null,
  revoked_at   timestamptz,
  created_by   uuid default auth.uid(),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz,
  pending_ops  int not null default 0 check (pending_ops >= 0),
  pending_at   timestamptz,
  check (valid_until > valid_from)
);
create table public.event_valet_sessions (
  id            uuid primary key default gen_random_uuid(),
  access_id     uuid not null references public.event_valet_access(id),
  employee_name text not null check (length(employee_name) between 2 and 40),
  started_at    timestamptz not null default now(),
  ended_at      timestamptz
);
create table public.event_valet_ops (
  access_id  uuid not null references public.event_valet_access(id),
  client_key text not null check (length(client_key) between 8 and 80),
  op         text not null,
  result     jsonb not null,
  created_at timestamptz not null default now(),
  primary key (access_id, client_key)
);
create table public.event_valet_rate (
  access_id uuid not null,
  bucket    timestamptz not null,
  n         int not null default 0,
  primary key (access_id, bucket)
);
create table public.event_valet_holds (
  event_id   text not null references public.event_valet_events(id),
  hook       int  not null check (hook > 0),
  access_id  uuid not null,
  client_key text not null,
  held_until timestamptz not null,
  primary key (event_id, hook)
);
create table public.event_valet_tips (
  id                uuid primary key default gen_random_uuid(),
  event_id          text not null references public.event_valet_events(id),
  ticket_id         uuid references public.event_valet_tickets(id),
  method            text not null default 'CASH' check (method = 'CASH'),
  amount_cents      int  not null check (amount_cents between 0 and 50000),
  employee_name     text,
  access_id         uuid,
  session_id        uuid,
  client_key        text,
  created_at        timestamptz not null default now(),
  corrected_from    int,
  correction_reason text,
  corrected_by      uuid,
  corrected_at      timestamptz,
  unique (access_id, client_key)
);
create index event_valet_tips_event on public.event_valet_tips (event_id, created_at);
alter table public.event_valet_access   enable row level security;
alter table public.event_valet_sessions enable row level security;
alter table public.event_valet_ops      enable row level security;
alter table public.event_valet_rate     enable row level security;
alter table public.event_valet_holds    enable row level security;
alter table public.event_valet_tips     enable row level security;
grant all on public.event_valet_access, public.event_valet_sessions, public.event_valet_ops,
             public.event_valet_rate, public.event_valet_holds, public.event_valet_tips to service_role;

-- ── helpers ─────────────────────────────────────────────────────────────
create or replace function public._ev_err(p_code text, p_detail jsonb default '{}'::jsonb)
returns void language plpgsql as $$
begin raise exception '%', p_code using detail = p_detail::text, errcode = 'P0001'; end $$;

create or replace function public.event_valet_staff_ticket(t public.event_valet_tickets)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'id', t.id, 'hook', t.slot_no, 'status', t.status, 'location', t.parking_location,
    'vehicle', jsonb_build_object('color', t.vehicle_color, 'make', t.vehicle_make, 'model', t.vehicle_model, 'plate', t.vehicle_plate),
    'vehicleText', t.vehicle, 'phoneLast4', right(t.phone_e164, 4), 'ticketCode', t.ticket_code,
    'checkedInAt', t.checked_in_at, 'checkedInBy', t.checked_in_by, 'keyStoredAt', t.key_stored_at, 'offline', t.offline_checkin,
    'requestedAt', t.requested_at, 'requestSource', t.request_source,
    'retrievingBy', t.retrieving_by, 'retrievingAt', t.retrieving_at, 'readyAt', t.ready_at,
    'deliveredAt', t.delivered_at, 'deliveredBy', t.delivered_by, 'updatedAt', t.updated_at);
$$;

-- first free hook for this caller (atomic under the event row lock taken by the caller)
create or replace function public._ev_alloc(ev public.event_valet_events, p_kind text, p_client_key text)
returns int language sql stable set search_path = public as $$
  with pools(ord, lo, hi) as (
    select 1, lower(case when p_kind = 'DEVICE' then ev.device_pool else ev.phone_pool end),
              upper(case when p_kind = 'DEVICE' then ev.device_pool else ev.phone_pool end) - 1
    union all
    select 2, lower(ev.phone_pool), upper(ev.phone_pool) - 1 where p_kind = 'DEVICE')
  select s from pools, generate_series(pools.lo, least(pools.hi, ev.slot_capacity)) s
   where not exists (select 1 from public.event_valet_tickets x
                      where x.event_id = ev.id and x.slot_no = s and x.status <> 'DELIVERED')
     and not exists (select 1 from public.event_valet_holds h
                      where h.event_id = ev.id and h.hook = s and h.held_until > now() and h.client_key <> coalesce(p_client_key, ''))
   order by pools.ord, s limit 1;
$$;

create or replace function public._ev_hook_free(ev public.event_valet_events, p_hook int, p_client_key text, p_except uuid default null)
returns boolean language sql stable set search_path = public as $$
  select p_hook between 1 and ev.slot_capacity
     and not exists (select 1 from public.event_valet_tickets x where x.event_id = ev.id and x.slot_no = p_hook
                      and x.status <> 'DELIVERED' and x.id is distinct from p_except)
     and not exists (select 1 from public.event_valet_holds h where h.event_id = ev.id and h.hook = p_hook
                      and h.held_until > now() and h.client_key <> coalesce(p_client_key, ''));
$$;

create or replace function public._ev_hook_allowed(ev public.event_valet_events, p_kind text, p_hook int)
returns boolean language sql immutable as $$
  -- LINK (backup phones) never touch the S710 pool: that is what makes S710 offline allocation safe.
  select case when p_kind = 'DEVICE' then p_hook between 1 and ev.slot_capacity else p_hook <@ ev.phone_pool end;
$$;

create or replace function public._ev_vehicle_text(v jsonb)
returns text language sql immutable as $$
  select upper(regexp_replace(btrim(case
    when coalesce(btrim(v->>'make'), '') <> '' then concat_ws(' ', nullif(btrim(v->>'color'), ''), btrim(v->>'make'), nullif(btrim(v->>'model'), ''))
    when coalesce(btrim(v->>'plate'), '') <> '' then 'PLATE ' || btrim(v->>'plate')
    else '' end), '\s+', ' ', 'g'));
$$;

create or replace function public._ev_counts(ev public.event_valet_events)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'active',     count(*) filter (where status <> 'DELIVERED'),
    'parked',     count(*) filter (where status = 'PARKED'),
    'requested',  count(*) filter (where status = 'REQUESTED'),
    'retrieving', count(*) filter (where status = 'RETRIEVING'),
    'ready',      count(*) filter (where status = 'READY'),
    'delivered',  count(*) filter (where status = 'DELIVERED'),
    'checkedIn',  count(*),
    'hooksFree',  ev.slot_capacity - count(*) filter (where status <> 'DELIVERED' and slot_no is not null))
  from public.event_valet_tickets where event_id = ev.id;
$$;

-- ── staff dispatcher (service_role only; the edge function passes the raw token) ──
create or replace function public.event_valet_staff(p_token text, p_session uuid, p_op text, p_body jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  a public.event_valet_access; ev public.event_valet_events; s public.event_valet_sessions; t public.event_valet_tickets;
  b jsonb := coalesce(p_body, '{}'::jsonb); v_ck text; v_res jsonb; v_prev public.event_valet_ops; v_n int;
  v_hook int; v_phone text; v_vehicle text; v_loc text; v_no int; v_code text; v_i int := 0; v_at timestamptz;
  v_to text; v_from text; v_who text; v_tip public.event_valet_tips; v_amt int; v_q text; v_digits text; v_notify text;
  v_actor jsonb; v_until timestamptz;
begin
  -- auth: token → access → event (+ session for everything but /session)
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$' then perform public._ev_err('AUTH'); end if;
  select * into a from public.event_valet_access where token_hash = sha256(convert_to(p_token, 'UTF8'));
  if not found then perform public._ev_err('AUTH'); end if;
  if a.revoked_at is not null then perform public._ev_err('REVOKED'); end if;
  if now() < a.valid_from or now() >= a.valid_until then perform public._ev_err('OUTSIDE_WINDOW'); end if;
  select * into ev from public.event_valet_events where id = a.event_id;
  if not ev.is_open or ev.closed_at is not null then perform public._ev_err('EVENT_CLOSED'); end if;
  if not ev.staff_access_enabled then perform public._ev_err('OUTSIDE_WINDOW', '{"why":"staff_access_off"}'); end if;
  insert into public.event_valet_rate (access_id, bucket, n) values (a.id, date_trunc('minute', now()), 1)
  on conflict (access_id, bucket) do update set n = public.event_valet_rate.n + 1 returning n into v_n;
  if v_n > 240 then perform public._ev_err('RATE_LIMIT'); end if;
  update public.event_valet_access set last_seen_at = now() where id = a.id;

  if p_op = 'session' then
    if length(btrim(coalesce(b->>'name', ''))) not between 2 and 40 then perform public._ev_err('BAD_INPUT', '{"field":"name"}'); end if;
    insert into public.event_valet_sessions (access_id, employee_name) values (a.id, initcap(btrim(b->>'name'))) returning * into s;
    insert into public.event_valet_audit (event_id, action, detail)
    values (ev.id, 'STAFF_SESSION', jsonb_build_object('actor', jsonb_build_object('access_id', a.id, 'kind', a.kind, 'label', a.label, 'employee_name', s.employee_name)));
    return jsonb_build_object('sessionId', s.id, 'employeeName', s.employee_name,
      'access', jsonb_build_object('kind', a.kind, 'label', a.label,
        'pool', jsonb_build_array(lower(case when a.kind = 'DEVICE' then ev.device_pool else ev.phone_pool end),
                                  upper(case when a.kind = 'DEVICE' then ev.device_pool else ev.phone_pool end) - 1)));
  end if;

  select * into s from public.event_valet_sessions where id = p_session and access_id = a.id and ended_at is null;
  if not found then perform public._ev_err('AUTH', '{"why":"session"}'); end if;
  v_actor := jsonb_build_object('access_id', a.id, 'kind', a.kind, 'label', a.label, 'employee_name', s.employee_name, 'session_id', s.id);

  -- read-only ops
  if p_op = 'state' then
    if b ? 'pending' and (b->>'pending') ~ '^\d{1,4}$' then
      update public.event_valet_access set pending_ops = (b->>'pending')::int, pending_at = now() where id = a.id;
    end if;
    return jsonb_build_object('serverTime', now(),
      'event', jsonb_build_object('id', ev.id, 'title', ev.title, 'date', ev.event_date, 'isOpen', ev.is_open,
        'locations', to_jsonb(ev.locations), 'capacity', ev.slot_capacity,
        'flags', jsonb_build_object('staffAccess', ev.staff_access_enabled, 'customerSms', ev.sms_enabled,
          'smsReplies', ev.sms_replies_enabled, 'tips', ev.tip_enabled, 'thanks', ev.thanks_enabled)),
      'me', jsonb_build_object('kind', a.kind, 'label', a.label, 'employeeName', s.employee_name, 'validUntil', a.valid_until),
      'counts', public._ev_counts(ev),
      'pools', jsonb_build_object('device', jsonb_build_array(lower(ev.device_pool), upper(ev.device_pool) - 1),
                                  'phone',  jsonb_build_array(lower(ev.phone_pool),  upper(ev.phone_pool) - 1)),
      'tickets', coalesce((select jsonb_agg(public.event_valet_staff_ticket(x) order by x.slot_no nulls last, x.ticket_no)
                             from public.event_valet_tickets x
                            where x.event_id = ev.id and (x.status <> 'DELIVERED' or x.delivered_at > now() - interval '60 minutes')), '[]'::jsonb));
  end if;
  if p_op = 'search' then
    v_q := btrim(coalesce(b->>'q', '')); v_digits := regexp_replace(v_q, '\D', '', 'g');
    if length(v_q) = 0 then return jsonb_build_object('tickets', '[]'::jsonb); end if;
    return jsonb_build_object('tickets', coalesce((select jsonb_agg(public.event_valet_staff_ticket(q.x) order by ((q.x).status = 'DELIVERED'), (q.x).slot_no)
      from (select x from public.event_valet_tickets x
             where x.event_id = ev.id and (x.status <> 'DELIVERED' or x.delivered_at > now() - interval '60 minutes')
               and ((v_q ~ '^#?\d{1,2}$' and x.slot_no = v_digits::int and x.status <> 'DELIVERED')
                 or (length(v_digits) >= 3 and v_digits = regexp_replace(v_q, '[\s()+-]', '', 'g')
                     and (x.phone_e164 like '%' || v_digits or x.ticket_code = v_digits))
                 or (v_q !~ '^[\d\s()#+-]+$' and (x.vehicle ilike '%' || v_q || '%' or replace(coalesce(x.vehicle_plate, ''), ' ', '') ilike '%' || replace(v_q, ' ', '') || '%')))
             limit 20) q), '[]'::jsonb));
  end if;

  -- mutating ops: idempotent per (access, clientKey)
  v_ck := b->>'clientKey';
  if v_ck is null or length(v_ck) not between 8 and 80 then perform public._ev_err('BAD_INPUT', '{"field":"clientKey"}'); end if;
  -- lock order everywhere: event row, then ticket (also serialises replays of one clientKey)
  select * into ev from public.event_valet_events where id = a.event_id for update;
  select * into v_prev from public.event_valet_ops where access_id = a.id and client_key = v_ck;
  if found then
    if v_prev.op <> p_op then perform public._ev_err('BAD_INPUT', '{"field":"clientKey","why":"reused"}'); end if;
    return v_prev.result || jsonb_build_object('replayed', true);
  end if;

  if p_op = 'hold' then
    delete from public.event_valet_holds where event_id = ev.id and held_until <= now();
    select hook into v_hook from public.event_valet_holds where event_id = ev.id and access_id = a.id and client_key = v_ck;
    if v_hook is null then
      v_hook := public._ev_alloc(ev, a.kind, v_ck);
      if v_hook is null then perform public._ev_err('HOOK_TAKEN', '{"suggestedHook":null,"why":"full"}'); end if;
      insert into public.event_valet_holds (event_id, hook, access_id, client_key, held_until)
      values (ev.id, v_hook, a.id, v_ck, now() + interval '3 minutes');
    else
      update public.event_valet_holds set held_until = now() + interval '3 minutes' where event_id = ev.id and hook = v_hook;
    end if;
    -- holds are not stored in ops: a later checkin with the same clientKey must still run
    return jsonb_build_object('hook', v_hook, 'heldUntil', now() + interval '3 minutes');

  elsif p_op = 'checkin' then
    v_phone := public.event_valet_normalize_phone(b->>'phone');
    if v_phone is null then perform public._ev_err('BAD_INPUT', '{"field":"phone"}'); end if;
    v_vehicle := public._ev_vehicle_text(coalesce(b->'vehicle', '{}'::jsonb));
    if length(v_vehicle) = 0 or length(v_vehicle) > 60 then perform public._ev_err('BAD_INPUT', '{"field":"vehicle"}'); end if;
    v_loc := b->>'location';
    if v_loc is null or not (v_loc = any (ev.locations)) then perform public._ev_err('BAD_INPUT', '{"field":"location"}'); end if;
    if b->>'keyStoredAt' is null then perform public._ev_err('BAD_INPUT', '{"field":"keyStoredAt"}'); end if;
    -- a retry of the same check-in that reached the DB through another path
    select * into t from public.event_valet_tickets where event_id = ev.id and client_key = v_ck;
    if found then
      v_res := jsonb_build_object('ticket', public.event_valet_staff_ticket(t), 'ticketId', t.id);
      insert into public.event_valet_ops values (a.id, v_ck, p_op, v_res); return v_res;
    end if;
    delete from public.event_valet_holds where event_id = ev.id and held_until <= now();
    if b->>'hook' is not null then
      if (b->>'hook') !~ '^\d{1,3}$' then perform public._ev_err('BAD_INPUT', '{"field":"hook"}'); end if;
      v_hook := (b->>'hook')::int;
      if not public._ev_hook_allowed(ev, a.kind, v_hook) then perform public._ev_err('BAD_INPUT', '{"field":"hook","why":"not_your_pool"}'); end if;
      if not public._ev_hook_free(ev, v_hook, v_ck) then
        perform public._ev_err('HOOK_TAKEN', jsonb_build_object('hook', v_hook, 'suggestedHook', public._ev_alloc(ev, a.kind, v_ck)));
      end if;
    else
      select hook into v_hook from public.event_valet_holds where event_id = ev.id and access_id = a.id and client_key = v_ck;
      if v_hook is null then v_hook := public._ev_alloc(ev, a.kind, v_ck); end if;
      if v_hook is null then perform public._ev_err('HOOK_TAKEN', '{"suggestedHook":null,"why":"full"}'); end if;
    end if;
    select coalesce(max(ticket_no), 0) + 1 into v_no from public.event_valet_tickets where event_id = ev.id;
    v_code := right(v_phone, 4);
    while exists (select 1 from public.event_valet_tickets where event_id = ev.id and ticket_code = v_code) loop
      v_i := v_i + 1;
      if v_i > 9 then perform public._ev_err('BAD_INPUT', '{"field":"phone","why":"too_many_cars"}'); end if;
      v_code := v_i::text || right(v_phone, 4);
    end loop;
    begin v_at := (b->>'keyStoredAt')::timestamptz; exception when others then v_at := now(); end;
    if v_at > now() + interval '2 minutes' or v_at < now() - interval '12 hours' then v_at := now(); end if;
    insert into public.event_valet_tickets (event_id, ticket_no, ticket_code, slot_no, phone_e164, vehicle, client_key,
        checked_in_at, parking_location, vehicle_color, vehicle_make, vehicle_model, vehicle_plate, key_stored_at,
        offline_checkin, checked_in_by, checked_in_access)
    values (ev.id, v_no, v_code, v_hook, v_phone, v_vehicle, v_ck,
        case when coalesce((b->>'offline')::boolean, false) then v_at else now() end, v_loc,
        nullif(upper(btrim(b#>>'{vehicle,color}')), ''), nullif(upper(btrim(b#>>'{vehicle,make}')), ''),
        nullif(upper(btrim(b#>>'{vehicle,model}')), ''), nullif(upper(regexp_replace(btrim(coalesce(b#>>'{vehicle,plate}', '')), '\s+', ' ', 'g')), ''),
        v_at, coalesce((b->>'offline')::boolean, false), s.employee_name, a.id)
    returning * into t;
    delete from public.event_valet_holds where event_id = ev.id and client_key = v_ck;
    insert into public.event_valet_audit (event_id, ticket_id, action, detail)
    values (ev.id, t.id, 'CHECK_IN', jsonb_build_object('actor', v_actor, 'hook', v_hook, 'offline', t.offline_checkin, 'ticket_no', v_no));
    v_res := jsonb_build_object('ticket', public.event_valet_staff_ticket(t), 'ticketId', t.id, 'notify', 'CHECKIN');

  elsif p_op in ('move-hook', 'status', 'edit') then
    if (b->>'ticketId') !~ '^[0-9a-f-]{36}$' then perform public._ev_err('BAD_INPUT', '{"field":"ticketId"}'); end if;
    select * into t from public.event_valet_tickets where id = (b->>'ticketId')::uuid and event_id = ev.id for update;
    if not found then perform public._ev_err('NOT_FOUND'); end if;
    if t.status = 'DELIVERED' then perform public._ev_err('BAD_INPUT', '{"why":"already_delivered"}'); end if;

    if p_op = 'move-hook' then
      if (b->>'hook') !~ '^\d{1,3}$' then perform public._ev_err('BAD_INPUT', '{"field":"hook"}'); end if;
      v_hook := (b->>'hook')::int;
      if not public._ev_hook_allowed(ev, a.kind, v_hook) then perform public._ev_err('BAD_INPUT', '{"field":"hook","why":"not_your_pool"}'); end if;
      if not public._ev_hook_free(ev, v_hook, v_ck, t.id) then
        perform public._ev_err('HOOK_TAKEN', jsonb_build_object('hook', v_hook, 'suggestedHook', public._ev_alloc(ev, a.kind, v_ck)));
      end if;
      v_from := t.slot_no::text;
      update public.event_valet_tickets set slot_no = v_hook, updated_at = now() where id = t.id returning * into t;
      insert into public.event_valet_audit (event_id, ticket_id, action, detail)
      values (ev.id, t.id, 'MOVE_HOOK', jsonb_build_object('actor', v_actor, 'from', v_from, 'to', v_hook));

    elsif p_op = 'edit' then
      if b ? 'location' and not ((b->>'location') = any (ev.locations)) then perform public._ev_err('BAD_INPUT', '{"field":"location"}'); end if;
      if b ? 'phone' and public.event_valet_normalize_phone(b->>'phone') is null then perform public._ev_err('BAD_INPUT', '{"field":"phone"}'); end if;
      if b ? 'vehicle' and length(public._ev_vehicle_text(b->'vehicle')) not between 1 and 60 then perform public._ev_err('BAD_INPUT', '{"field":"vehicle"}'); end if;
      update public.event_valet_tickets set
        parking_location = case when b ? 'location' then b->>'location' else parking_location end,
        phone_e164       = case when b ? 'phone' then public.event_valet_normalize_phone(b->>'phone') else phone_e164 end,
        vehicle          = case when b ? 'vehicle' then public._ev_vehicle_text(b->'vehicle') else vehicle end,
        vehicle_color    = case when b ? 'vehicle' then nullif(upper(btrim(b#>>'{vehicle,color}')), '') else vehicle_color end,
        vehicle_make     = case when b ? 'vehicle' then nullif(upper(btrim(b#>>'{vehicle,make}')), '') else vehicle_make end,
        vehicle_model    = case when b ? 'vehicle' then nullif(upper(btrim(b#>>'{vehicle,model}')), '') else vehicle_model end,
        vehicle_plate    = case when b ? 'vehicle' then nullif(upper(btrim(b#>>'{vehicle,plate}')), '') else vehicle_plate end,
        updated_at = now()
      where id = t.id returning * into t;
      insert into public.event_valet_audit (event_id, ticket_id, action, detail)
      values (ev.id, t.id, 'EDIT', jsonb_build_object('actor', v_actor, 'fields', (select jsonb_agg(k) from jsonb_object_keys(b - 'clientKey' - 'ticketId') k)));

    else -- status
      v_to := b->>'to'; v_from := t.status;
      if v_to not in ('REQUESTED','RETRIEVING','READY','DELIVERED','PARKED') then perform public._ev_err('BAD_INPUT', '{"field":"to"}'); end if;
      if v_to = 'RETRIEVING' and t.status = 'RETRIEVING' and t.retrieving_session is distinct from s.id then
        perform public._ev_err('TAKEN_BY', jsonb_build_object('by', t.retrieving_by));
      end if;
      if v_to = 'PARKED' and t.status not in ('REQUESTED','RETRIEVING') then perform public._ev_err('BAD_INPUT', '{"why":"cannot_park"}'); end if;
      if v_to = 'REQUESTED' and t.status not in ('PARKED','RETRIEVING') then perform public._ev_err('BAD_INPUT', '{"why":"cannot_request"}'); end if;
      if v_to <> t.status then
        update public.event_valet_tickets set
          status             = v_to,
          requested_at       = case when v_to = 'PARKED' then null
                                    when v_to = 'REQUESTED' and t.status = 'PARKED' then now()
                                    else coalesce(requested_at, now()) end,
          request_source     = case when v_to = 'PARKED' then null
                                    when v_to = 'REQUESTED' and t.status = 'PARKED' then 'STAFF'
                                    else coalesce(request_source, 'STAFF') end,
          retrieving_by      = case when v_to in ('PARKED','REQUESTED') then null when v_to = 'RETRIEVING' or retrieving_by is null then s.employee_name else retrieving_by end,
          retrieving_access  = case when v_to in ('PARKED','REQUESTED') then null when v_to = 'RETRIEVING' or retrieving_access is null then a.id else retrieving_access end,
          retrieving_session = case when v_to in ('PARKED','REQUESTED') then null when v_to = 'RETRIEVING' or retrieving_session is null then s.id else retrieving_session end,
          retrieving_at      = case when v_to in ('PARKED','REQUESTED') then null when v_to = 'RETRIEVING' then now() else coalesce(retrieving_at, now()) end,
          ready_at           = case when v_to = 'READY' then now() when v_to = 'DELIVERED' then ready_at else null end,
          delivered_at       = case when v_to = 'DELIVERED' then now() else null end,
          delivered_by       = case when v_to = 'DELIVERED' then s.employee_name else null end,
          updated_at         = now()
        where id = t.id returning * into t;
        insert into public.event_valet_audit (event_id, ticket_id, action, detail)
        values (ev.id, t.id, 'STATUS', jsonb_build_object('actor', v_actor, 'from', v_from, 'to', v_to, 'source', 'STAFF_API'));
        v_notify := case v_to when 'RETRIEVING' then 'ONWAY' when 'READY' then 'READY' when 'DELIVERED' then 'THANKS' else null end;
      end if;
    end if;
    v_res := jsonb_build_object('ticket', public.event_valet_staff_ticket(t), 'ticketId', t.id)
             || case when v_notify is not null then jsonb_build_object('notify', v_notify) else '{}'::jsonb end;

  elsif p_op = 'cash-tip' then
    if (b->>'amountCents') !~ '^\d{3,5}$' or (b->>'amountCents')::int not between 100 and 50000 then
      perform public._ev_err('BAD_INPUT', '{"field":"amountCents"}');
    end if;
    v_amt := (b->>'amountCents')::int;
    if b->>'ticketId' is not null then
      if (b->>'ticketId') !~ '^[0-9a-f-]{36}$' or not exists (select 1 from public.event_valet_tickets where id = (b->>'ticketId')::uuid and event_id = ev.id) then
        perform public._ev_err('NOT_FOUND', '{"field":"ticketId"}');
      end if;
    end if;
    select * into v_tip from public.event_valet_tips
     where event_id = ev.id and ticket_id is not distinct from (b->>'ticketId')::uuid and amount_cents = v_amt
       and created_at > now() - interval '3 minutes' order by created_at desc limit 1;
    if found and not coalesce((b->>'confirmDuplicate')::boolean, false) then
      perform public._ev_err('DUPLICATE_CASH', jsonb_build_object('existing', jsonb_build_object('id', v_tip.id, 'amountCents', v_tip.amount_cents,
        'createdAt', v_tip.created_at, 'employeeName', v_tip.employee_name)));
    end if;
    insert into public.event_valet_tips (event_id, ticket_id, amount_cents, employee_name, access_id, session_id, client_key)
    values (ev.id, (b->>'ticketId')::uuid, v_amt, s.employee_name, a.id, s.id, v_ck) returning * into v_tip;
    insert into public.event_valet_audit (event_id, ticket_id, action, detail)
    values (ev.id, v_tip.ticket_id, 'CASH_TIP', jsonb_build_object('actor', v_actor, 'tip_id', v_tip.id, 'amount_cents', v_amt));
    v_res := jsonb_build_object('tip', jsonb_build_object('id', v_tip.id, 'amountCents', v_tip.amount_cents, 'ticketId', v_tip.ticket_id,
                                'employeeName', v_tip.employee_name, 'createdAt', v_tip.created_at));
  else
    perform public._ev_err('NOT_FOUND', '{"why":"op"}');
  end if;

  insert into public.event_valet_ops (access_id, client_key, op, result) values (a.id, v_ck, p_op, v_res);
  return v_res;
end $$;

-- ── admin (authenticated ADMIN only) ────────────────────────────────────
create or replace function public._ev_admin() returns void language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(public.current_user_role()::text, '') <> 'ADMIN' then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
end $$;

create or replace function public.event_valet_admin_access_create(p_event text, p_kind text, p_label text, p_valid_until timestamptz, p_valid_from timestamptz default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_tok text := rtrim(translate(encode(gen_random_bytes(32), 'base64'), '+/', '-_'), '='); r public.event_valet_access;
begin
  perform public._ev_admin();
  if p_kind not in ('DEVICE','LINK') then raise exception 'BAD_KIND' using errcode = '22023'; end if;
  insert into public.event_valet_access (event_id, kind, label, token_hash, valid_from, valid_until)
  values (p_event, p_kind, btrim(p_label), sha256(convert_to(v_tok, 'UTF8')), coalesce(p_valid_from, now()), p_valid_until)
  returning * into r;
  insert into public.event_valet_audit (event_id, action, detail)
  values (p_event, 'ACCESS_CREATE', jsonb_build_object('access_id', r.id, 'kind', r.kind, 'label', r.label, 'valid_until', r.valid_until));
  return jsonb_build_object('id', r.id, 'token', v_tok, 'kind', r.kind, 'label', r.label, 'validFrom', r.valid_from, 'validUntil', r.valid_until);
end $$;

create or replace function public.event_valet_admin_access_list(p_event text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public._ev_admin();
  return coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'kind', x.kind, 'label', x.label, 'validFrom', x.valid_from,
      'validUntil', x.valid_until, 'revokedAt', x.revoked_at, 'lastSeenAt', x.last_seen_at, 'pendingOps', x.pending_ops,
      'employees', (select coalesce(jsonb_agg(distinct se.employee_name), '[]'::jsonb) from public.event_valet_sessions se where se.access_id = x.id))
      order by x.created_at) from public.event_valet_access x where x.event_id = p_event), '[]'::jsonb);
end $$;

create or replace function public.event_valet_admin_access_revoke(p_access uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.event_valet_access;
begin
  perform public._ev_admin();
  update public.event_valet_access set revoked_at = coalesce(revoked_at, now()) where id = p_access returning * into r;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  insert into public.event_valet_audit (event_id, action, detail) values (r.event_id, 'ACCESS_REVOKE', jsonb_build_object('access_id', r.id, 'label', r.label));
  return jsonb_build_object('id', r.id, 'revokedAt', r.revoked_at);
end $$;

create or replace function public.event_valet_admin_access_extend(p_event text, p_valid_until timestamptz)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  perform public._ev_admin();
  update public.event_valet_access set valid_until = p_valid_until
   where event_id = p_event and revoked_at is null and valid_until < p_valid_until and p_valid_until > valid_from;
  get diagnostics v_n = row_count;
  insert into public.event_valet_audit (event_id, action, detail) values (p_event, 'ACCESS_EXTEND', jsonb_build_object('valid_until', p_valid_until, 'count', v_n));
  return jsonb_build_object('extended', v_n, 'validUntil', p_valid_until);
end $$;

create or replace function public.event_valet_admin_set_flags(p_event text, p_flags jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ev public.event_valet_events;
begin
  perform public._ev_admin();
  update public.event_valet_events set
    staff_access_enabled = coalesce((p_flags->>'staffAccess')::boolean, staff_access_enabled),
    sms_enabled          = coalesce((p_flags->>'customerSms')::boolean, sms_enabled),
    sms_test_only        = coalesce((p_flags->>'smsTestOnly')::boolean, sms_test_only),
    sms_replies_enabled  = coalesce((p_flags->>'smsReplies')::boolean, sms_replies_enabled),
    tip_enabled          = coalesce((p_flags->>'tips')::boolean, tip_enabled),
    thanks_enabled       = coalesce((p_flags->>'thanks')::boolean, thanks_enabled)
  where id = p_event and closed_at is null returning * into ev;
  if not found then raise exception 'NOT_FOUND_OR_CLOSED' using errcode = 'P0002'; end if;
  insert into public.event_valet_audit (event_id, action, detail) values (p_event, 'FLAGS', p_flags);
  return jsonb_build_object('staffAccess', ev.staff_access_enabled, 'customerSms', ev.sms_enabled, 'smsTestOnly', ev.sms_test_only,
    'smsReplies', ev.sms_replies_enabled, 'tips', ev.tip_enabled, 'thanks', ev.thanks_enabled);
end $$;

create or replace function public.event_valet_admin_cash_correct(p_tip uuid, p_amount_cents int, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.event_valet_tips; v_old int;
begin
  perform public._ev_admin();
  if p_amount_cents not between 0 and 50000 then raise exception 'BAD_AMOUNT' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'REASON_REQUIRED' using errcode = '22023'; end if;
  select * into r from public.event_valet_tips where id = p_tip for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  v_old := r.amount_cents;
  update public.event_valet_tips set amount_cents = p_amount_cents, corrected_from = coalesce(corrected_from, v_old),
         correction_reason = btrim(p_reason), corrected_by = auth.uid(), corrected_at = now()
   where id = p_tip returning * into r;
  insert into public.event_valet_audit (event_id, ticket_id, action, detail)
  values (r.event_id, r.ticket_id, 'CASH_CORRECT', jsonb_build_object('tip_id', r.id, 'from', v_old, 'to', p_amount_cents, 'reason', btrim(p_reason)));
  return jsonb_build_object('id', r.id, 'amountCents', r.amount_cents, 'from', v_old);
end $$;

create or replace function public._ev_blockers(ev public.event_valet_events)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(b), '[]'::jsonb) from (
    select jsonb_build_object('code', 'ACTIVE_VEHICLES', 'count', count(*)) b from public.event_valet_tickets
     where event_id = ev.id and status <> 'DELIVERED' having count(*) > 0
    union all
    select jsonb_build_object('code', 'PENDING_OPS', 'count', sum(pending_ops), 'devices', jsonb_agg(label)) from public.event_valet_access
     where event_id = ev.id and revoked_at is null and pending_ops > 0 having count(*) > 0) q;
$$;

create or replace function public.event_valet_admin_report(p_event text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare ev public.event_valet_events; v_peak int; v_peak_at timestamptz;
begin
  perform public._ev_admin();
  select * into ev from public.event_valet_events where id = p_event;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  select n, at into v_peak, v_peak_at from (
    select at, sum(d) over (order by at, d rows unbounded preceding) n from (
      select checked_in_at at, 1 d from public.event_valet_tickets where event_id = p_event
      union all select delivered_at, -1 from public.event_valet_tickets where event_id = p_event and delivered_at is not null) e) x
   order by n desc, at limit 1;
  return jsonb_build_object(
    'event', jsonb_build_object('id', ev.id, 'title', ev.title, 'date', ev.event_date, 'isOpen', ev.is_open, 'closedAt', ev.closed_at,
       'revenueSlug', ev.revenue_slug, 'capacity', ev.slot_capacity,
       'flags', jsonb_build_object('staffAccess', ev.staff_access_enabled, 'customerSms', ev.sms_enabled, 'smsTestOnly', ev.sms_test_only,
          'smsReplies', ev.sms_replies_enabled, 'tips', ev.tip_enabled, 'thanks', ev.thanks_enabled)),
    'counts', public._ev_counts(ev),
    'peak', jsonb_build_object('count', coalesce(v_peak, 0), 'at', v_peak_at),
    'avgRetrievalSeconds', (select round(avg(extract(epoch from delivered_at - requested_at)))::int from public.event_valet_tickets
                             where event_id = p_event and delivered_at is not null and requested_at is not null),
    'employees', coalesce((select jsonb_agg(e order by e->>'name') from (
        select jsonb_build_object('name', n,
          'checkins',   (select count(*) from public.event_valet_tickets where event_id = p_event and checked_in_by = n),
          'retrievals', (select count(*) from public.event_valet_tickets where event_id = p_event and retrieving_by = n),
          'deliveries', (select count(*) from public.event_valet_tickets where event_id = p_event and delivered_by = n),
          'cashCents',  (select coalesce(sum(amount_cents), 0) from public.event_valet_tips where event_id = p_event and employee_name = n)) e
        from (select checked_in_by n from public.event_valet_tickets where event_id = p_event and checked_in_by is not null
              union select retrieving_by from public.event_valet_tickets where event_id = p_event and retrieving_by is not null
              union select delivered_by from public.event_valet_tickets where event_id = p_event and delivered_by is not null
              union select employee_name from public.event_valet_tips where event_id = p_event and employee_name is not null) names) q), '[]'::jsonb),
    'cash', jsonb_build_object(
       'totalCents', (select coalesce(sum(amount_cents), 0) from public.event_valet_tips where event_id = p_event),
       'count',      (select count(*) from public.event_valet_tips where event_id = p_event),
       'tips', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'ticketId', x.ticket_id, 'hook', t.slot_no, 'amountCents', x.amount_cents,
                 'employeeName', x.employee_name, 'createdAt', x.created_at, 'correctedFrom', x.corrected_from,
                 'correctionReason', x.correction_reason, 'correctedAt', x.corrected_at) order by x.created_at)
                 from public.event_valet_tips x left join public.event_valet_tickets t on t.id = x.ticket_id where x.event_id = p_event), '[]'::jsonb)),
    'vehicles', coalesce((select jsonb_agg(public.event_valet_staff_ticket(t) order by t.ticket_no) from public.event_valet_tickets t where t.event_id = p_event), '[]'::jsonb),
    'blockers', public._ev_blockers(ev));
end $$;

create or replace function public.event_valet_admin_close(p_event text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare ev public.event_valet_events; v_block jsonb;
begin
  perform public._ev_admin();
  select * into ev from public.event_valet_events where id = p_event for update;
  if not found then raise exception 'NOT_FOUND' using errcode = 'P0002'; end if;
  if ev.closed_at is not null then return jsonb_build_object('closed', true, 'closedAt', ev.closed_at, 'already', true); end if;
  v_block := public._ev_blockers(ev);
  if jsonb_array_length(v_block) > 0 then return jsonb_build_object('closed', false, 'blockers', v_block); end if;
  update public.event_valet_events set is_open = false, closed_at = now(), staff_access_enabled = false, sms_replies_enabled = false
   where id = p_event returning * into ev;
  update public.event_valet_access set revoked_at = coalesce(revoked_at, now()) where event_id = p_event;
  delete from public.event_valet_holds where event_id = p_event;
  insert into public.event_valet_audit (event_id, action, detail) values (p_event, 'CLOSE', jsonb_build_object('closed_at', ev.closed_at));
  return jsonb_build_object('closed', true, 'closedAt', ev.closed_at);
end $$;

-- READY routing pre-check for the shared AirValet number (service_role only).
-- EVENT = an active car in an open event that accepts replies; CROSS = that AND an
-- active Makers Air passenger on the same phone (never guess); NONE = not ours.
create or replace function public.event_valet_route_check(p_phone text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_n int; v_pax int := 0; v_ev text;
begin
  select count(*), min(t.event_id) into v_n, v_ev from public.event_valet_tickets t join public.event_valet_events e on e.id = t.event_id
   where e.is_open and e.closed_at is null and e.sms_replies_enabled and t.phone_e164 = p_phone and t.status <> 'DELIVERED';
  if v_n = 0 then return jsonb_build_object('route', 'NONE'); end if;
  if to_regclass('public.passengers') is not null then
    execute $q$ select count(*) from public.passengers p
                 where public.airvalet_sms_normalize_phone(p.phone) = $1 and p.status in ('PENDING','NO DATE') $q$
      into v_pax using p_phone;
  end if;
  return jsonb_build_object('route', case when v_pax > 0 then 'CROSS' else 'EVENT' end, 'eventId', v_ev, 'activeCars', v_n);
end $$;

revoke all on function public._ev_err(text, jsonb) from public, anon, authenticated;
revoke all on function public.event_valet_staff_ticket(public.event_valet_tickets) from public, anon, authenticated;
revoke all on function public._ev_alloc(public.event_valet_events, text, text) from public, anon, authenticated;
revoke all on function public._ev_hook_free(public.event_valet_events, int, text, uuid) from public, anon, authenticated;
revoke all on function public._ev_hook_allowed(public.event_valet_events, text, int) from public, anon, authenticated;
revoke all on function public._ev_vehicle_text(jsonb) from public, anon, authenticated;
revoke all on function public._ev_counts(public.event_valet_events) from public, anon, authenticated;
revoke all on function public._ev_blockers(public.event_valet_events) from public, anon, authenticated;
revoke all on function public.event_valet_staff(text, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.event_valet_route_check(text) from public, anon, authenticated;
revoke all on function public._ev_admin() from public, anon;
grant execute on function public.event_valet_staff(text, uuid, text, jsonb) to service_role;
grant execute on function public.event_valet_route_check(text) to service_role;
revoke all on function public.event_valet_admin_access_create(text, text, text, timestamptz, timestamptz) from public, anon;
revoke all on function public.event_valet_admin_access_list(text) from public, anon;
revoke all on function public.event_valet_admin_access_revoke(uuid) from public, anon;
revoke all on function public.event_valet_admin_access_extend(text, timestamptz) from public, anon;
revoke all on function public.event_valet_admin_set_flags(text, jsonb) from public, anon;
revoke all on function public.event_valet_admin_cash_correct(uuid, int, text) from public, anon;
revoke all on function public.event_valet_admin_report(text) from public, anon;
revoke all on function public.event_valet_admin_close(text) from public, anon;
grant execute on function public._ev_admin() to authenticated;
grant execute on function public.event_valet_admin_access_create(text, text, text, timestamptz, timestamptz) to authenticated;
grant execute on function public.event_valet_admin_access_list(text) to authenticated;
grant execute on function public.event_valet_admin_access_revoke(uuid) to authenticated;
grant execute on function public.event_valet_admin_access_extend(text, timestamptz) to authenticated;
grant execute on function public.event_valet_admin_set_flags(text, jsonb) to authenticated;
grant execute on function public.event_valet_admin_cash_correct(uuid, int, text) to authenticated;
grant execute on function public.event_valet_admin_report(text) to authenticated;
grant execute on function public.event_valet_admin_close(text) to authenticated;

-- ── Watermakers row ─────────────────────────────────────────────────────
update public.event_valet_events
   set slot_capacity = 50, device_pool = '[1,41)', phone_pool = '[41,51)',
       include_ticket_link = true, revenue_slug = 'watermakers-2026-11-11'
 where id = 'watermakers-veterans-2026';

commit;

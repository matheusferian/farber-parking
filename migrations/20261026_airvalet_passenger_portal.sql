-- AirValet passenger portal (Valet Pass) — LOCAL ONLY until owner GO.
-- Requires the Twilio migrations already in production (20261009 / 20261010 /
-- 20261011) and the return-date history (20260717).
--
-- Owner decisions (2026-10-25, P1–P10):
--   P1  return time is optional; never invented (passengers.ret_time stays null
--       until staff or an approved passenger request sets it).
--   P2  the ticket number is internal: the portal never returns it.
--   P3  Customs is shown only when the team confirmed it (Ascend included).
--   P4  "Ready" is set by staff only.
--   P5  lockbox details only after staff authorization; the code is returned
--       only from the reveal day on (America/New_York).
--   P6  valet hours are configurable (airvalet_portal_settings.valet_hours).
--   P7  no unverified phone numbers (reservations_phone / text_phone start null).
--   P8  gratuity = the existing Matt Solutions Payment Link only.
--   P9  Valet Terms link hidden until terms_published.
--   P10 printed tickets / QR untouched (nothing here touches printing).
-- Passenger requests (return change, car wash) are PENDING until staff decide;
-- the operational record changes only on approval, through the existing
-- atomic change_passenger_return_date_with_reason() (history + activity log).
-- Nothing here sends SMS. Everything starts OFF (portal_enabled = false).

begin;

-- ── 1. passengers: optional return time (P1) ──────────────────────────────
alter table public.passengers add column if not exists ret_time time;

-- ── 2. Settings (single row) ──────────────────────────────────────────────
create table public.airvalet_portal_settings (
  id                    boolean primary key default true check (id),
  portal_enabled        boolean not null default false,
  requests_enabled      boolean not null default false,
  valet_hours           jsonb   not null default '{}'::jsonb,  -- {"mon":["05:30","17:30"], …}; {} = not shown
  valet_phone           text    default '(954) 352-1010',      -- printed on the customer ticket
  text_phone            text,                                  -- AirValet SMS number, set when replies reach the Inbox
  reservations_phone    text,                                  -- P7: null until verified by the owner
  car_wash_lead_hours   integer not null default 48 check (car_wash_lead_hours between 1 and 240),
  gratuity_url          text check (gratuity_url is null or gratuity_url ~ '^https://buy\.stripe\.com/[A-Za-z0-9]{8,64}$'),
  terms_published       boolean not null default false,
  push_enabled          boolean not null default false,
  tv_alerts_enabled     boolean not null default true,
  updated_at            timestamptz not null default now(),
  updated_by            uuid,
  check (jsonb_typeof(valet_hours) = 'object')
);
-- Matt Solutions Payment Link already used by AirValet texts today (verified 2026-10-23).
insert into public.airvalet_portal_settings (id, gratuity_url) values (true, 'https://buy.stripe.com/8x214mccK0uh9TjgIM6Vq00');

-- Super Admins (owner's personal logins only; never the shared "Admin").
create table public.airvalet_super_admins (
  user_id    uuid primary key,
  note       text,
  created_at timestamptz not null default now()
);

-- ── 3. Staff-only passenger state (P3, P4, P5) ────────────────────────────
create table public.airvalet_pass_state (
  passenger_id          bigint primary key references public.passengers(id) on delete cascade,
  ready_at              timestamptz,
  ready_by              uuid,
  customs_confirmed_at  timestamptz,
  customs_confirmed_by  uuid,
  lockbox_authorized_at timestamptz,
  lockbox_authorized_by uuid,
  lockbox_reveal_on     date,
  lockbox_code          text check (lockbox_code is null or lockbox_code ~ '^[A-Za-z0-9-]{2,12}$'),
  updated_at            timestamptz not null default now(),
  check (lockbox_authorized_at is not null or (lockbox_code is null and lockbox_reveal_on is null))
);

-- ── 4. Passenger requests ─────────────────────────────────────────────────
create table public.airvalet_pass_requests (
  id                uuid primary key default gen_random_uuid(),
  passenger_id      bigint not null references public.passengers(id) on delete cascade,
  pass_link_id      bigint references public.airvalet_pass_links(id) on delete set null,
  kind              text not null check (kind in ('RETURN_CHANGE', 'CAR_WASH')),
  reason            text check (reason in ('NEW_DATE_TIME', 'FLIGHT_CHANGED', 'OTHER_CARRIER', 'AFTER_HOURS')),
  requested_date    date,
  requested_time    time,
  carrier           text check (carrier is null or char_length(carrier) between 2 and 40),
  note              text check (note is null or char_length(note) <= 280),
  snapshot_ret      text,
  snapshot_ret_time time,
  status            text not null default 'PENDING'
                      check (status in ('PENDING', 'APPROVED', 'DECLINED', 'CANCELLED', 'SUPERSEDED')),
  client_key        text not null unique check (client_key ~ '^[A-Za-z0-9_-]{16,64}$'),
  created_at        timestamptz not null default now(),
  decided_at        timestamptz,
  decided_by        uuid,
  decided_by_email  text,
  decision_note     text check (decision_note is null or char_length(decision_note) <= 280),
  check ((kind = 'RETURN_CHANGE') = (reason is not null)),
  check (kind <> 'RETURN_CHANGE' or requested_date is not null),
  check (reason is distinct from 'OTHER_CARRIER' or carrier is not null),
  check ((status in ('PENDING', 'SUPERSEDED', 'CANCELLED')) or decided_at is not null)
);
create unique index airvalet_pass_requests_one_pending
  on public.airvalet_pass_requests (passenger_id, kind) where status = 'PENDING';
create index airvalet_pass_requests_recent on public.airvalet_pass_requests (created_at desc);

-- ── 5. Alert signals (no personal data) for Realtime: Inbox, iPad, TV ──────
create table public.airvalet_alert_events (
  id         bigint generated always as identity primary key,
  kind       text not null check (kind in ('GUEST_MESSAGE', 'PASS_REQUEST', 'SMS_FAILURE')),
  ref_id     uuid not null,
  created_at timestamptz not null default now()
);
create index airvalet_alert_events_recent on public.airvalet_alert_events (created_at desc);

-- ── 6. Web Push (approved devices only) + notification dedupe ─────────────
create table public.airvalet_push_subs (
  id            uuid primary key default gen_random_uuid(),
  device_id     uuid not null references public.airvalet_sms_devices(id) on delete cascade,
  endpoint      text not null unique check (char_length(endpoint) between 20 and 1000 and endpoint ~ '^https://\S+$'),
  p256dh        text not null check (char_length(p256dh) between 40 and 200),
  auth          text not null check (char_length(auth) between 10 and 60),
  show_preview  boolean not null default false,   -- lock screen shows no message text by default
  fail_count    integer not null default 0,
  created_at    timestamptz not null default now(),
  last_ok_at    timestamptz,
  revoked_at    timestamptz
);

create table public.airvalet_notify_log (
  dedupe_key  text primary key check (char_length(dedupe_key) between 5 and 200),
  channel     text not null check (channel in ('push', 'admin_sms')),
  status      text not null default 'claimed' check (status in ('claimed', 'sent', 'failed', 'skipped')),
  segments    integer,
  provider_sid text,
  detail      text,
  created_at  timestamptz not null default now()
);
create index airvalet_notify_log_recent on public.airvalet_notify_log (channel, created_at desc);

-- Super Admin SMS copy (single row). Phone verified by code before use.
create table public.airvalet_admin_alerts (
  id                      boolean primary key default true check (id),
  enabled                 boolean not null default false,
  phone_e164              text check (phone_e164 is null or phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  phone_verified_at       timestamptz,
  verify_code_hash        bytea,
  verify_expires_at       timestamptz,
  verify_attempts         integer not null default 0,
  notify_guest_messages   boolean not null default true,
  notify_pass_requests    boolean not null default false,
  notify_sms_failures     boolean not null default false,
  notify_operational      boolean not null default false,
  daily_cap               integer not null default 30 check (daily_cap between 1 and 200),
  per_guest_window_min    integer not null default 10 check (per_guest_window_min between 1 and 240),
  updated_at              timestamptz not null default now(),
  updated_by              uuid,
  check (not enabled or (phone_e164 is not null and phone_verified_at is not null))
);
insert into public.airvalet_admin_alerts (id) values (true);

-- ── RLS / grants: no direct table access; everything through RPCs ──────────
alter table public.airvalet_portal_settings enable row level security;
alter table public.airvalet_super_admins    enable row level security;
alter table public.airvalet_pass_state      enable row level security;
alter table public.airvalet_pass_requests   enable row level security;
alter table public.airvalet_alert_events    enable row level security;
alter table public.airvalet_push_subs       enable row level security;
alter table public.airvalet_notify_log      enable row level security;
alter table public.airvalet_admin_alerts    enable row level security;
revoke all on public.airvalet_portal_settings, public.airvalet_super_admins, public.airvalet_pass_state,
              public.airvalet_pass_requests, public.airvalet_alert_events, public.airvalet_push_subs,
              public.airvalet_notify_log, public.airvalet_admin_alerts
  from public, anon, authenticated;
grant all on public.airvalet_portal_settings, public.airvalet_super_admins, public.airvalet_pass_state,
             public.airvalet_pass_requests, public.airvalet_alert_events, public.airvalet_push_subs,
             public.airvalet_notify_log, public.airvalet_admin_alerts
  to service_role;
-- Realtime needs SELECT under RLS. Requests: ops roles. Alert signals: ops +
-- TV (ids and kinds only — the TV then asks airvalet_tv_alerts()).
grant select on public.airvalet_pass_requests to authenticated;
create policy airvalet_pass_requests_select_ops on public.airvalet_pass_requests
  for select to authenticated
  using (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]));
grant select on public.airvalet_alert_events to authenticated;
create policy airvalet_alert_events_select on public.airvalet_alert_events
  for select to authenticated
  using (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER','TV_ONLY']::public.account_role[]));

-- ── Helpers ───────────────────────────────────────────────────────────────
create or replace function public.airvalet_portal_require_ops()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or public.current_user_role() is null
     or not (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[])) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
end $$;

create or replace function public.airvalet_portal_require_admin()
returns void language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or public.current_user_role() is distinct from 'ADMIN'::public.account_role then
    raise exception 'not allowed' using errcode = '42501';
  end if;
end $$;

create or replace function public.airvalet_is_super_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null
     and public.current_user_role() = 'ADMIN'::public.account_role
     and exists (select 1 from public.airvalet_super_admins s where s.user_id = auth.uid());
$$;

-- Return moment in America/New_York (date + optional time; no time = 00:00,
-- the conservative choice for the 48-hour car wash rule).
create or replace function public.airvalet_return_at(p_ret text, p_time time)
returns timestamptz language plpgsql stable set search_path = '' as $$
declare v_d date;
begin
  if p_ret is null or btrim(p_ret) !~ '^\d{1,2}/\d{1,2}/\d{4}$' then return null; end if;
  begin
    v_d := to_date(btrim(p_ret), 'MM/DD/YYYY');
  exception when others then return null;
  end;
  return (v_d + coalesce(p_time, time '00:00')) at time zone 'America/New_York';
end $$;

-- Resolve a portal token: same throttles and the SAME 'expired' answer for
-- unknown / malformed / revoked / expired / archived links as airvalet_pass_view.
create or replace function public.airvalet_portal_resolve(p_token text, p_client text, out o_state text, out o_link_id bigint, out o_passenger_id bigint)
language plpgsql security definer set search_path = '' as $$
declare
  c_client_max   constant int := 30;
  c_client_fails constant int := 8;
  c_global_fails constant int := 2000;
  v_client text := coalesce(nullif(p_client, ''), 'none');
  v_win    timestamptz := date_bin('10 minutes', now(), timestamptz '2000-01-01');
  v_link   public.airvalet_pass_links%rowtype;
  v_p      public.passengers%rowtype;
  v_ok     boolean := false;
begin
  if random() < 0.01 then
    delete from public.airvalet_pass_rate r where r.window_start < now() - interval '1 hour';
  end if;
  if public.airvalet_pass_hit('c:' || v_client) > c_client_max
     or coalesce((select r.hits from public.airvalet_pass_rate r where r.bucket = 'f:' || v_client and r.window_start = v_win), 0) >= c_client_fails then
    o_state := 'limited'; return;
  end if;
  if not coalesce((select s.portal_enabled from public.airvalet_portal_settings s), false) then
    o_state := 'expired'; return;  -- dark launch: indistinguishable from an unknown link
  end if;
  if p_token ~ '^[A-Za-z0-9]{17}$' then
    select * into v_link from public.airvalet_pass_links l
     where l.token_hash = extensions.digest(p_token, 'sha256') and l.revoked_at is null;
    if found then
      select * into v_p from public.passengers p where p.id = v_link.passenger_id;
      v_ok := found and v_p.status <> 'ARCHIVED'
        and (case when v_link.expires_at is not null then now() < v_link.expires_at
                  else v_p.status in ('PENDING', 'NO DATE') end);
    end if;
  end if;
  if not v_ok then
    perform public.airvalet_pass_hit('f:' || v_client);
    o_state := case when public.airvalet_pass_hit('f:*') > c_global_fails then 'limited' else 'expired' end;
    return;
  end if;
  o_state := 'ok'; o_link_id := v_link.id; o_passenger_id := v_p.id;
end $$;

-- ── Public portal view (called only by the valet-pass Edge Function) ──────
-- Never returns: ticket, phone, key location, internal ids, other passengers.
create or replace function public.airvalet_portal_view(p_token text, p_client text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r        record;
  v_p      public.passengers%rowtype;
  v_st     public.airvalet_pass_state%rowtype;
  v_set    public.airvalet_portal_settings%rowtype;
  v_req    public.airvalet_pass_requests%rowtype;
  v_wash   public.airvalet_pass_requests%rowtype;
  v_pickup text;
  v_status text;
  v_ret_at timestamptz;
  v_today  date := (now() at time zone 'America/New_York')::date;
  v_wash_state text;
  v_vehicle text;
begin
  select * into r from public.airvalet_portal_resolve(p_token, p_client);
  if r.o_state <> 'ok' then return jsonb_build_object('state', r.o_state); end if;

  select * into v_p   from public.passengers p where p.id = r.o_passenger_id;
  select * into v_st  from public.airvalet_pass_state s where s.passenger_id = v_p.id;
  select * into v_set from public.airvalet_portal_settings;
  select * into v_req from public.airvalet_pass_requests q
   where q.passenger_id = v_p.id and q.kind = 'RETURN_CHANGE' and q.status = 'PENDING';
  select * into v_wash from public.airvalet_pass_requests q
   where q.passenger_id = v_p.id and q.kind = 'CAR_WASH' and q.status = 'PENDING';

  update public.airvalet_pass_links l
     set first_opened_at = coalesce(l.first_opened_at, now()), last_opened_at = now(), open_count = l.open_count + 1
   where l.id = r.o_link_id;

  -- P3: Customs only when the team confirmed it. MAKERS + approved exception
  -- (delivery_at_customs) is a staff decision already; ASCEND needs the
  -- explicit confirmation. Until then: no pickup place is promised.
  v_pickup := case
    when v_p.return_operator = 'MAKERS' and coalesce(v_p.delivery_at_customs, false) then 'CUSTOMS_EXCEPTION'
    when v_p.return_operator = 'MAKERS' then 'HANGAR_19'
    when v_p.return_operator = 'ASCEND' and v_st.customs_confirmed_at is not null then 'CUSTOMS_ASCEND'
    when v_p.return_operator = 'ASCEND' then 'TO_BE_CONFIRMED'
    else 'OTHER' end;
  v_status := case
    when v_p.status = 'DELIVERED' then 'DELIVERED'
    when v_pickup in ('CUSTOMS_EXCEPTION', 'CUSTOMS_ASCEND') and v_st.ready_at is not null then 'CUSTOMS_CONFIRMED'
    when v_st.ready_at is not null then 'READY'
    else 'PARKED' end;

  v_ret_at := public.airvalet_return_at(v_p.ret, v_p.ret_time);
  v_wash_state := case
    when v_p.status not in ('PENDING', 'NO DATE') or v_st.ready_at is not null then 'NONE'
    when v_wash.id is not null then 'REQUESTED'
    when v_p.carwash_status = 'CARWASH' then 'SCHEDULED'
    when v_p.carwash_status = 'SEND_PRICE' then 'PRICE_PENDING'
    when v_p.carwash_status = 'WASHED' then 'DONE'
    when v_ret_at is not null and v_ret_at - now() >= make_interval(hours => v_set.car_wash_lead_hours) then 'REQUEST'
    else 'CONTACT' end;
  v_vehicle := nullif(btrim(concat_ws(' ', nullif(btrim(coalesce(v_p.color, '')), ''), nullif(btrim(coalesce(v_p.car, '')), ''))), '');

  return jsonb_build_object(
    'state', 'ok',
    'pass', jsonb_build_object(
      'first_name', nullif(initcap(split_part(btrim(coalesce(v_p.name, '')), ' ', 1)), ''),
      'vehicle', v_vehicle,
      'status', v_status,
      'pickup', v_pickup,
      'return_date', nullif(btrim(coalesce(v_p.ret, '')), ''),
      'return_time', to_char(v_p.ret_time, 'HH24:MI'),
      'pending_return', case when v_req.id is null then null else jsonb_build_object(
          'reason', v_req.reason, 'date', v_req.requested_date, 'time', to_char(v_req.requested_time, 'HH24:MI'),
          'carrier', v_req.carrier, 'created_at', v_req.created_at) end,
      'car_wash', v_wash_state,
      'car_wash_lead_hours', v_set.car_wash_lead_hours,
      'lockbox', case when v_st.lockbox_authorized_at is null or v_status = 'DELIVERED' then null else jsonb_build_object(
          'authorized', true,
          'reveal_on', v_st.lockbox_reveal_on,
          'code', case when v_st.lockbox_reveal_on is not null and v_today >= v_st.lockbox_reveal_on then v_st.lockbox_code end) end,
      'requests_enabled', v_set.requests_enabled and v_p.status in ('PENDING', 'NO DATE'),
      'valet_hours', v_set.valet_hours,
      'contacts', jsonb_strip_nulls(jsonb_build_object(
          'valet_phone', v_set.valet_phone, 'text_phone', v_set.text_phone, 'reservations_phone', v_set.reservations_phone)),
      'gratuity_url', v_set.gratuity_url,
      'terms_published', v_set.terms_published
    ));
end $$;

-- ── Passenger request (valet-pass Edge Function only) ─────────────────────
create or replace function public.airvalet_portal_request(
  p_token text, p_client text, p_kind text, p_reason text, p_date date, p_time time,
  p_carrier text, p_note text, p_client_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r        record;
  v_p      public.passengers%rowtype;
  v_st     public.airvalet_pass_state%rowtype;
  v_set    public.airvalet_portal_settings%rowtype;
  v_today  date := (now() at time zone 'America/New_York')::date;
  v_ret_at timestamptz;
  v_prev   public.airvalet_pass_requests%rowtype;
  v_id     uuid;
  v_note   text := nullif(btrim(regexp_replace(coalesce(p_note, ''), '[[:cntrl:]]+', ' ', 'g')), '');
  v_carrier text := nullif(btrim(regexp_replace(coalesce(p_carrier, ''), '[[:cntrl:]]+', ' ', 'g')), '');
begin
  select * into r from public.airvalet_portal_resolve(p_token, p_client);
  if r.o_state <> 'ok' then return jsonb_build_object('state', r.o_state); end if;
  select * into v_set from public.airvalet_portal_settings;
  if not v_set.requests_enabled then return jsonb_build_object('state', 'ok', 'result', 'UNAVAILABLE'); end if;
  if coalesce(p_client_key, '') !~ '^[A-Za-z0-9_-]{16,64}$' then return jsonb_build_object('state', 'ok', 'result', 'INVALID'); end if;

  -- Same client key again (double tap / retry): return the original answer.
  select * into v_prev from public.airvalet_pass_requests q where q.client_key = p_client_key;
  if found then
    if v_prev.passenger_id <> r.o_passenger_id then return jsonb_build_object('state', 'ok', 'result', 'INVALID'); end if;
    return jsonb_build_object('state', 'ok', 'result', 'OK', 'request_id', v_prev.id, 'duplicate', true);
  end if;

  -- Per-link daily brake (abuse of a leaked link).
  if public.airvalet_pass_hit('r:' || r.o_link_id || ':' || v_today) > 12 then
    return jsonb_build_object('state', 'ok', 'result', 'LIMITED');
  end if;

  select * into v_p from public.passengers p where p.id = r.o_passenger_id for update;
  if v_p.status not in ('PENDING', 'NO DATE') then return jsonb_build_object('state', 'ok', 'result', 'NOT_IN_CUSTODY'); end if;
  if v_note is not null and char_length(v_note) > 280 then return jsonb_build_object('state', 'ok', 'result', 'INVALID'); end if;

  if p_kind = 'RETURN_CHANGE' then
    if p_reason not in ('NEW_DATE_TIME', 'FLIGHT_CHANGED', 'OTHER_CARRIER', 'AFTER_HOURS')
       or p_date is null or p_date < v_today or p_date > v_today + 365 then
      return jsonb_build_object('state', 'ok', 'result', 'INVALID');
    end if;
    if p_reason = 'OTHER_CARRIER' and (v_carrier is null or char_length(v_carrier) not between 2 and 40) then
      return jsonb_build_object('state', 'ok', 'result', 'INVALID');
    end if;
  elsif p_kind = 'CAR_WASH' then
    select * into v_st from public.airvalet_pass_state s where s.passenger_id = v_p.id;
    v_ret_at := public.airvalet_return_at(v_p.ret, v_p.ret_time);
    if v_p.carwash_status is not null or v_st.ready_at is not null then
      return jsonb_build_object('state', 'ok', 'result', 'NOT_AVAILABLE');
    end if;
    if v_ret_at is null or v_ret_at - now() < make_interval(hours => v_set.car_wash_lead_hours) then
      return jsonb_build_object('state', 'ok', 'result', 'CONTACT_TEAM');   -- < 48 h: ask the team
    end if;
  else
    return jsonb_build_object('state', 'ok', 'result', 'INVALID');
  end if;

  -- A newer request of the same kind replaces the pending one (history kept).
  update public.airvalet_pass_requests q set status = 'SUPERSEDED'
   where q.passenger_id = v_p.id and q.kind = p_kind and q.status = 'PENDING';

  insert into public.airvalet_pass_requests (
    passenger_id, pass_link_id, kind, reason, requested_date, requested_time, carrier, note,
    snapshot_ret, snapshot_ret_time, client_key)
  values (
    v_p.id, r.o_link_id, p_kind,
    case when p_kind = 'RETURN_CHANGE' then p_reason end,
    case when p_kind = 'RETURN_CHANGE' then p_date end,
    case when p_kind = 'RETURN_CHANGE' then p_time end,
    case when p_kind = 'RETURN_CHANGE' and p_reason = 'OTHER_CARRIER' then v_carrier end,
    v_note, v_p.ret, v_p.ret_time, p_client_key)
  returning id into v_id;

  return jsonb_build_object('state', 'ok', 'result', 'OK', 'request_id', v_id, 'passenger_id', v_p.id);
exception when unique_violation then
  -- Concurrent duplicate of the same client key: report the stored one.
  select * into v_prev from public.airvalet_pass_requests q where q.client_key = p_client_key;
  return jsonb_build_object('state', 'ok', 'result', 'OK', 'request_id', v_prev.id, 'duplicate', true);
end $$;

-- ── Staff: list + decide requests ─────────────────────────────────────────
create or replace function public.airvalet_pass_requests_list(p_days integer default 7)
returns table (
  id uuid, passenger_id bigint, passenger_name text, ticket text, vehicle text, kind text, reason text,
  requested_date date, requested_time text, carrier text, note text, snapshot_ret text, snapshot_ret_time text,
  current_ret text, current_ret_time text, status text, created_at timestamptz, decided_at timestamptz,
  decided_by_email text, decision_note text, carwash_status text, return_operator text)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.airvalet_portal_require_ops();
  return query
  select q.id, q.passenger_id, p.name, p.ticket, nullif(btrim(concat_ws(' ', p.color, p.car)), ''), q.kind, q.reason,
         q.requested_date, to_char(q.requested_time, 'HH24:MI'), q.carrier, q.note, q.snapshot_ret, to_char(q.snapshot_ret_time, 'HH24:MI'),
         p.ret, to_char(p.ret_time, 'HH24:MI'), q.status, q.created_at, q.decided_at, q.decided_by_email, q.decision_note,
         p.carwash_status, p.return_operator
    from public.airvalet_pass_requests q
    join public.passengers p on p.id = q.passenger_id
   where q.status = 'PENDING' or q.created_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 60)))
   order by (q.status = 'PENDING') desc, q.created_at desc
   limit 200;
end $$;

-- APPROVE: RETURN_CHANGE → existing atomic return-date change (history +
-- activity log) and/or the new time; CAR_WASH → existing SEND_PRICE flow.
-- OTHER_CARRIER / AFTER_HOURS never change return_operator, Customs or the
-- lockbox by themselves (staff use the existing controls).
-- 'STALE' when the official return changed after the request (staff review again with p_force).
create or replace function public.airvalet_pass_request_decide(p_id uuid, p_decision text, p_note text default null, p_force boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_q      public.airvalet_pass_requests%rowtype;
  v_p      public.passengers%rowtype;
  v_email  text;
  v_new_ret text;
  v_reason text;
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform public.airvalet_portal_require_ops();
  if p_decision not in ('APPROVE', 'DECLINE') then raise exception 'invalid decision' using errcode = '22023'; end if;
  if v_note is not null and char_length(v_note) > 280 then raise exception 'note too long' using errcode = '22023'; end if;
  v_email := coalesce(nullif(btrim(auth.jwt() ->> 'email'), ''), auth.uid()::text);

  select * into v_q from public.airvalet_pass_requests q where q.id = p_id for update;
  if not found then return jsonb_build_object('result', 'NOT_FOUND'); end if;
  if v_q.status <> 'PENDING' then return jsonb_build_object('result', 'ALREADY_DECIDED', 'status', v_q.status); end if;
  select * into v_p from public.passengers p where p.id = v_q.passenger_id for update;

  if p_decision = 'DECLINE' then
    update public.airvalet_pass_requests q set status = 'DECLINED', decided_at = now(), decided_by = auth.uid(),
           decided_by_email = v_email, decision_note = v_note where q.id = p_id;
    return jsonb_build_object('result', 'DECLINED');
  end if;

  if v_q.kind = 'RETURN_CHANGE' then
    if not p_force and (coalesce(public._normalize_ret_date(v_p.ret), '') is distinct from coalesce(public._normalize_ret_date(v_q.snapshot_ret), '')
                        or v_p.ret_time is distinct from v_q.snapshot_ret_time) then
      return jsonb_build_object('result', 'STALE', 'current_ret', v_p.ret, 'current_ret_time', to_char(v_p.ret_time, 'HH24:MI'));
    end if;
    v_new_ret := to_char(v_q.requested_date, 'FMMM/FMDD/YYYY');
    v_reason := 'Passenger request (' || lower(replace(v_q.reason, '_', ' ')) || ')'
             || coalesce(': ' || v_q.carrier, '') || coalesce(' - ' || v_q.note, '');
    v_reason := left(v_reason, 500);
    if coalesce(public._normalize_ret_date(v_p.ret), '') is distinct from coalesce(public._normalize_ret_date(v_new_ret), '') then
      perform public.change_passenger_return_date_with_reason(v_p.id, v_new_ret, v_reason, false);
    end if;
    if v_p.ret_time is distinct from v_q.requested_time then
      update public.passengers p set ret_time = v_q.requested_time where p.id = v_p.id;
      insert into public.activity_log (ts, action, passenger, ticket, location, detail, passenger_id, changed_by, field_name, old_value, new_value)
      values (to_char(now(), 'MM/DD/YYYY, HH12:MI:SS AM'), 'RETURN TIME', v_p.name, v_p.ticket, v_p.loc,
              'Return time changed: ' || coalesce(to_char(v_p.ret_time, 'HH24:MI'), 'not set') || ' → '
              || coalesce(to_char(v_q.requested_time, 'HH24:MI'), 'not set') || ' | Reason: ' || v_reason,
              v_p.id, v_email, 'ret_time', to_char(v_p.ret_time, 'HH24:MI'), to_char(v_q.requested_time, 'HH24:MI'));
    end if;
  elsif v_q.kind = 'CAR_WASH' then
    if v_p.carwash_status is null then
      update public.passengers p set carwash_status = 'SEND_PRICE' where p.id = v_p.id;
      insert into public.activity_log (ts, action, passenger, ticket, location, detail, passenger_id, changed_by, field_name, old_value, new_value)
      values (to_char(now(), 'MM/DD/YYYY, HH12:MI:SS AM'), 'EDITED', v_p.name, v_p.ticket, v_p.loc,
              'Car wash requested by passenger (portal) → Send Price', v_p.id, v_email, 'carwash_status', null, 'SEND_PRICE');
    end if;
  end if;

  update public.airvalet_pass_requests q set status = 'APPROVED', decided_at = now(), decided_by = auth.uid(),
         decided_by_email = v_email, decision_note = v_note where q.id = p_id;
  return jsonb_build_object('result', 'APPROVED');
end $$;

-- ── Staff: passenger portal state (Ready / Customs / Lockbox) ─────────────
create or replace function public.airvalet_pass_state_get(p_passenger_id bigint)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v public.airvalet_pass_state%rowtype;
begin
  perform public.airvalet_portal_require_ops();
  select * into v from public.airvalet_pass_state s where s.passenger_id = p_passenger_id;
  return jsonb_build_object(
    'ready', v.ready_at is not null, 'ready_at', v.ready_at,
    'customs_confirmed', v.customs_confirmed_at is not null,
    'lockbox_authorized', v.lockbox_authorized_at is not null, 'lockbox_reveal_on', v.lockbox_reveal_on,
    'lockbox_code', v.lockbox_code);
end $$;

create or replace function public.airvalet_pass_state_set(p_passenger_id bigint, p_field text, p_value jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_p public.passengers%rowtype;
  v_on boolean := coalesce((p_value ->> 'on')::boolean, false);
  v_email text;
  v_detail text;
begin
  perform public.airvalet_portal_require_ops();
  select * into v_p from public.passengers p where p.id = p_passenger_id for update;
  if not found then raise exception 'passenger not found' using errcode = 'P0002'; end if;
  v_email := coalesce(nullif(btrim(auth.jwt() ->> 'email'), ''), auth.uid()::text);
  insert into public.airvalet_pass_state (passenger_id) values (p_passenger_id) on conflict (passenger_id) do nothing;
  if p_field = 'ready' then
    update public.airvalet_pass_state s set ready_at = case when v_on then coalesce(s.ready_at, now()) end,
           ready_by = case when v_on then auth.uid() end, updated_at = now() where s.passenger_id = p_passenger_id;
    v_detail := 'Valet pass: Ready ' || case when v_on then 'ON' else 'OFF' end;
  elsif p_field = 'customs_confirmed' then
    update public.airvalet_pass_state s set customs_confirmed_at = case when v_on then coalesce(s.customs_confirmed_at, now()) end,
           customs_confirmed_by = case when v_on then auth.uid() end, updated_at = now() where s.passenger_id = p_passenger_id;
    v_detail := 'Valet pass: Customs confirmed ' || case when v_on then 'ON' else 'OFF' end;
  elsif p_field = 'lockbox' then
    if v_on then
      if coalesce(p_value ->> 'code', '') !~ '^[A-Za-z0-9-]{2,12}$' or (p_value ->> 'reveal_on') is null then
        raise exception 'lockbox needs a code and a reveal day' using errcode = '22023';
      end if;
      update public.airvalet_pass_state s set lockbox_authorized_at = now(), lockbox_authorized_by = auth.uid(),
             lockbox_code = p_value ->> 'code', lockbox_reveal_on = (p_value ->> 'reveal_on')::date, updated_at = now()
       where s.passenger_id = p_passenger_id;
      v_detail := 'Valet pass: after-hours lockbox authorized (shown from ' || (p_value ->> 'reveal_on') || ')';
    else
      update public.airvalet_pass_state s set lockbox_authorized_at = null, lockbox_authorized_by = null,
             lockbox_code = null, lockbox_reveal_on = null, updated_at = now() where s.passenger_id = p_passenger_id;
      v_detail := 'Valet pass: after-hours lockbox removed';
    end if;
  else
    raise exception 'invalid field' using errcode = '22023';
  end if;
  -- The code itself is never written to the activity log.
  insert into public.activity_log (ts, action, passenger, ticket, location, detail, passenger_id, changed_by, field_name)
  values (to_char(now(), 'MM/DD/YYYY, HH12:MI:SS AM'), 'VALET PASS', v_p.name, v_p.ticket, v_p.loc, v_detail, v_p.id, v_email, p_field);
  return public.airvalet_pass_state_get(p_passenger_id);
end $$;

-- ── Settings (read: ops; write: ADMIN only — never IPHONE_OPS / IPAD_OPS) ──
create or replace function public.airvalet_portal_settings_get()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v public.airvalet_portal_settings%rowtype;
begin
  perform public.airvalet_portal_require_ops();
  select * into v from public.airvalet_portal_settings;
  return to_jsonb(v) - 'id' - 'updated_by';
end $$;

create or replace function public.airvalet_portal_settings_set(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k text;
begin
  perform public.airvalet_portal_require_admin();
  for k in select jsonb_object_keys(p_patch) loop
    if k not in ('portal_enabled', 'requests_enabled', 'valet_hours', 'valet_phone', 'text_phone', 'reservations_phone',
                 'car_wash_lead_hours', 'gratuity_url', 'terms_published', 'push_enabled', 'tv_alerts_enabled') then
      raise exception 'unknown setting %', k using errcode = '22023';
    end if;
  end loop;
  update public.airvalet_portal_settings s set
    portal_enabled      = coalesce((p_patch ->> 'portal_enabled')::boolean, s.portal_enabled),
    requests_enabled    = coalesce((p_patch ->> 'requests_enabled')::boolean, s.requests_enabled),
    valet_hours         = coalesce(p_patch -> 'valet_hours', s.valet_hours),
    valet_phone         = case when p_patch ? 'valet_phone' then nullif(btrim(p_patch ->> 'valet_phone'), '') else s.valet_phone end,
    text_phone          = case when p_patch ? 'text_phone' then nullif(btrim(p_patch ->> 'text_phone'), '') else s.text_phone end,
    reservations_phone  = case when p_patch ? 'reservations_phone' then nullif(btrim(p_patch ->> 'reservations_phone'), '') else s.reservations_phone end,
    car_wash_lead_hours = coalesce((p_patch ->> 'car_wash_lead_hours')::int, s.car_wash_lead_hours),
    gratuity_url        = case when p_patch ? 'gratuity_url' then nullif(btrim(p_patch ->> 'gratuity_url'), '') else s.gratuity_url end,
    terms_published     = coalesce((p_patch ->> 'terms_published')::boolean, s.terms_published),
    push_enabled        = coalesce((p_patch ->> 'push_enabled')::boolean, s.push_enabled),
    tv_alerts_enabled   = coalesce((p_patch ->> 'tv_alerts_enabled')::boolean, s.tv_alerts_enabled),
    updated_at = now(), updated_by = auth.uid();
  return public.airvalet_portal_settings_get();
end $$;

-- ── TV Mode alerts (TV + ops; minimal data; never marks anything read) ─────
create or replace function public.airvalet_tv_alerts()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_role public.account_role := public.current_user_role();
begin
  if auth.uid() is null or v_role is null
     or not (v_role = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER','TV_ONLY']::public.account_role[])) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if not coalesce((select s.tv_alerts_enabled from public.airvalet_portal_settings s), false) then
    return jsonb_build_object('enabled', false, 'unread', 0, 'pending_requests', 0, 'latest', '[]'::jsonb);
  end if;
  return jsonb_build_object(
    'enabled', true,
    'unread', (select count(*) from public.airvalet_sms_messages m
                where m.direction = 'inbound' and m.message_type = 'INBOUND' and m.read_at is null),
    'pending_requests', (select count(*) from public.airvalet_pass_requests q where q.status = 'PENDING'),
    'latest', coalesce((
      select jsonb_agg(x order by x.at desc) from (
        select m.id::text as id, 'MESSAGE' as kind, m.received_at as at,
               coalesce(nullif(initcap(split_part(btrim(coalesce(p.name, '')), ' ', 1)), '') ||
                 coalesce(' ' || upper(left(nullif(split_part(btrim(coalesce(p.name, '')), ' ', 2), ''), 1)) || '.', ''), 'Guest') as who,
               p.ticket as ticket,
               left(regexp_replace(coalesce(m.body, ''), '\s+', ' ', 'g'), 80) as text
          from public.airvalet_sms_messages m
          left join public.passengers p on p.id = m.passenger_id
         where m.direction = 'inbound' and m.message_type = 'INBOUND' and m.read_at is null
           and m.received_at > now() - interval '30 minutes'
        union all
        select q.id::text, 'REQUEST', q.created_at,
               coalesce(nullif(initcap(split_part(btrim(coalesce(p.name, '')), ' ', 1)), '') ||
                 coalesce(' ' || upper(left(nullif(split_part(btrim(coalesce(p.name, '')), ' ', 2), ''), 1)) || '.', ''), 'Guest'),
               p.ticket,
               case q.kind when 'CAR_WASH' then 'Car wash request'
                           else 'Return change: ' || to_char(q.requested_date, 'Mon DD') || coalesce(' ' || to_char(q.requested_time, 'HH12:MI AM'), '') end
          from public.airvalet_pass_requests q join public.passengers p on p.id = q.passenger_id
         where q.status = 'PENDING' and q.created_at > now() - interval '30 minutes'
        order by 3 desc limit 5) x), '[]'::jsonb));
end $$;

-- ── Web Push subscription (approved devices only) ─────────────────────────
create or replace function public.airvalet_push_subscribe(p_device_key text, p_endpoint text, p_p256dh text, p_auth text, p_show_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_dev uuid;
begin
  perform public.airvalet_portal_require_ops();
  select d.id into v_dev from public.airvalet_sms_devices d
   where d.key_hash = public.airvalet_sms_device_key_hash(p_device_key) and d.status = 'approved';
  if v_dev is null then return jsonb_build_object('result', 'DEVICE_NOT_AUTHORIZED'); end if;
  insert into public.airvalet_push_subs (device_id, endpoint, p256dh, auth, show_preview)
  values (v_dev, p_endpoint, p_p256dh, p_auth, coalesce(p_show_preview, false))
  on conflict (endpoint) do update set device_id = excluded.device_id, p256dh = excluded.p256dh, auth = excluded.auth,
         show_preview = excluded.show_preview, revoked_at = null, fail_count = 0;
  return jsonb_build_object('result', 'OK');
end $$;

create or replace function public.airvalet_push_unsubscribe(p_endpoint text)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.airvalet_portal_require_ops();
  update public.airvalet_push_subs s set revoked_at = now() where s.endpoint = p_endpoint and s.revoked_at is null;
  return jsonb_build_object('result', 'OK');
end $$;

-- ── Notifications (Edge Functions, service_role only) ─────────────────────
-- Push targets: active subscriptions of devices still approved.
create or replace function public.airvalet_push_targets()
returns table (id uuid, endpoint text, p256dh text, auth text, show_preview boolean)
language sql stable security definer set search_path = '' as $$
  select s.id, s.endpoint, s.p256dh, s.auth, s.show_preview
    from public.airvalet_push_subs s join public.airvalet_sms_devices d on d.id = s.device_id
   where s.revoked_at is null and s.fail_count < 5 and d.status = 'approved'
     and coalesce((select ps.push_enabled from public.airvalet_portal_settings ps), false);
$$;

create or replace function public.airvalet_push_result(p_id uuid, p_ok boolean, p_gone boolean)
returns void language sql security definer set search_path = '' as $$
  update public.airvalet_push_subs s
     set fail_count = case when p_ok then 0 else s.fail_count + 1 end,
         last_ok_at = case when p_ok then now() else s.last_ok_at end,
         revoked_at = case when p_gone then now() else s.revoked_at end
   where s.id = p_id;
$$;

-- One claim per (event, channel): true = this caller sends it.
create or replace function public.airvalet_notify_claim(p_dedupe_key text, p_channel text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_n int;
begin
  insert into public.airvalet_notify_log (dedupe_key, channel) values (p_dedupe_key, p_channel)
  on conflict (dedupe_key) do nothing;
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;

create or replace function public.airvalet_notify_finish(p_dedupe_key text, p_status text, p_segments integer, p_sid text, p_detail text)
returns void language sql security definer set search_path = '' as $$
  update public.airvalet_notify_log n set status = p_status, segments = p_segments, provider_sid = p_sid, detail = left(p_detail, 200)
   where n.dedupe_key = p_dedupe_key;
$$;

-- Admin SMS copy gate: returns the verified phone when this event may be
-- texted (enabled, event type on, daily cap, per-guest window), else null.
-- Serialized so two events at the same moment can't both pass the cap.
create or replace function public.airvalet_admin_alert_target(p_event text, p_passenger_id bigint, p_phone_e164 text)
returns text language plpgsql security definer set search_path = '' as $$
declare a public.airvalet_admin_alerts%rowtype;
begin
  perform pg_advisory_xact_lock(hashtextextended('airvalet_admin_alerts', 0));
  select * into a from public.airvalet_admin_alerts;
  if not a.enabled or a.phone_e164 is null or a.phone_verified_at is null then return null; end if;
  if p_phone_e164 = a.phone_e164 then return null; end if;          -- never about the admin phone itself
  if (p_event = 'GUEST_MESSAGE' and not a.notify_guest_messages)
     or (p_event = 'PASS_REQUEST' and not a.notify_pass_requests)
     or (p_event = 'SMS_FAILURE' and not a.notify_sms_failures) then return null; end if;
  if (select count(*) from public.airvalet_notify_log n
       where n.channel = 'admin_sms' and n.status in ('claimed', 'sent')
         and n.created_at > now() - interval '24 hours') >= a.daily_cap then return null; end if;
  if p_passenger_id is not null and exists (
       select 1 from public.airvalet_notify_log n
        where n.channel = 'admin_sms' and n.status in ('claimed', 'sent')
          and n.dedupe_key like 'admin:%:p' || p_passenger_id || ':%'
          and n.created_at > now() - make_interval(mins => a.per_guest_window_min)) then return null; end if;
  return a.phone_e164;
end $$;

create or replace function public.airvalet_is_admin_alert_phone(p_phone_e164 text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.airvalet_admin_alerts a where a.phone_e164 = p_phone_e164);
$$;

-- Details for one notification (service_role): minimal, no phone number.
create or replace function public.airvalet_notify_details(p_kind text, p_ref uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare r record;
begin
  if p_kind = 'GUEST_MESSAGE' then
    select m.id, m.passenger_id, m.phone_e164, m.body, p.name, p.ticket into r
      from public.airvalet_sms_messages m left join public.passengers p on p.id = m.passenger_id
     where m.id = p_ref and m.direction = 'inbound' and m.message_type = 'INBOUND';
    if not found then return null; end if;
    return jsonb_build_object('kind', p_kind, 'passenger_id', r.passenger_id, 'phone_e164', r.phone_e164,
      'name', initcap(coalesce(nullif(btrim(r.name), ''), 'Guest')), 'ticket', r.ticket, 'text', left(coalesce(r.body, ''), 300));
  elsif p_kind = 'PASS_REQUEST' then
    select q.id, q.passenger_id, q.kind, q.requested_date, q.requested_time, p.name, p.ticket into r
      from public.airvalet_pass_requests q join public.passengers p on p.id = q.passenger_id where q.id = p_ref;
    if not found then return null; end if;
    return jsonb_build_object('kind', p_kind, 'passenger_id', r.passenger_id, 'phone_e164', null,
      'name', initcap(coalesce(nullif(btrim(r.name), ''), 'Guest')), 'ticket', r.ticket,
      'text', case r.kind when 'CAR_WASH' then 'Car wash request'
                          else 'Return change to ' || to_char(r.requested_date, 'Mon DD') || coalesce(' ' || to_char(r.requested_time, 'HH12:MI AM'), '') end);
  end if;
  return null;
end $$;

-- ── Super Admin SMS alert settings ────────────────────────────────────────
create or replace function public.airvalet_admin_alerts_get()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare a public.airvalet_admin_alerts%rowtype;
begin
  if not public.airvalet_is_super_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into a from public.airvalet_admin_alerts;
  return jsonb_build_object(
    'enabled', a.enabled, 'phone_e164', a.phone_e164, 'phone_verified', a.phone_verified_at is not null,
    'notify_guest_messages', a.notify_guest_messages, 'notify_pass_requests', a.notify_pass_requests,
    'notify_sms_failures', a.notify_sms_failures, 'notify_operational', a.notify_operational,
    'daily_cap', a.daily_cap, 'per_guest_window_min', a.per_guest_window_min,
    'last_24h', (select count(*) from public.airvalet_notify_log n where n.channel = 'admin_sms' and n.status = 'sent' and n.created_at > now() - interval '24 hours'),
    'last_30d_segments', (select coalesce(sum(n.segments), 0) from public.airvalet_notify_log n where n.channel = 'admin_sms' and n.status = 'sent' and n.created_at > now() - interval '30 days'));
end $$;

create or replace function public.airvalet_admin_alerts_set(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a public.airvalet_admin_alerts%rowtype; k text;
begin
  if not public.airvalet_is_super_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  for k in select jsonb_object_keys(p_patch) loop
    if k not in ('enabled', 'notify_guest_messages', 'notify_pass_requests', 'notify_sms_failures', 'notify_operational',
                 'daily_cap', 'per_guest_window_min') then
      raise exception 'unknown setting %', k using errcode = '22023';
    end if;
  end loop;
  select * into a from public.airvalet_admin_alerts for update;
  if coalesce((p_patch ->> 'enabled')::boolean, false) and a.phone_verified_at is null then
    raise exception 'verify the phone number first' using errcode = '22023';
  end if;
  update public.airvalet_admin_alerts s set
    enabled               = coalesce((p_patch ->> 'enabled')::boolean, s.enabled),
    notify_guest_messages = coalesce((p_patch ->> 'notify_guest_messages')::boolean, s.notify_guest_messages),
    notify_pass_requests  = coalesce((p_patch ->> 'notify_pass_requests')::boolean, s.notify_pass_requests),
    notify_sms_failures   = coalesce((p_patch ->> 'notify_sms_failures')::boolean, s.notify_sms_failures),
    notify_operational    = coalesce((p_patch ->> 'notify_operational')::boolean, s.notify_operational),
    daily_cap             = coalesce((p_patch ->> 'daily_cap')::int, s.daily_cap),
    per_guest_window_min  = coalesce((p_patch ->> 'per_guest_window_min')::int, s.per_guest_window_min),
    updated_at = now(), updated_by = auth.uid();
  return public.airvalet_admin_alerts_get();
end $$;

-- Phone verification: the Edge Function (JWT of a Super Admin) asks for a
-- code; the plaintext goes to the phone only. Changing the phone disables
-- alerts until verified again.
create or replace function public.airvalet_admin_alerts_start_verify(p_user uuid, p_phone_e164 text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_code text := lpad((floor(random() * 1000000))::int::text, 6, '0');
begin
  if not exists (select 1 from public.airvalet_super_admins s where s.user_id = p_user)
     or (select up.role from public.user_profiles up where up.id = p_user) is distinct from 'ADMIN'::public.account_role then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if p_phone_e164 !~ '^\+1[2-9][0-9]{9}$' then raise exception 'invalid US phone' using errcode = '22023'; end if;
  update public.airvalet_admin_alerts a set
    phone_e164 = p_phone_e164, phone_verified_at = case when a.phone_e164 = p_phone_e164 then a.phone_verified_at end,
    enabled = case when a.phone_e164 = p_phone_e164 then a.enabled else false end,
    verify_code_hash = extensions.digest(v_code || ':' || p_phone_e164, 'sha256'),
    verify_expires_at = now() + interval '10 minutes', verify_attempts = 0, updated_at = now(), updated_by = p_user;
  return v_code;
end $$;

create or replace function public.airvalet_admin_alerts_confirm(p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare a public.airvalet_admin_alerts%rowtype;
begin
  if not public.airvalet_is_super_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into a from public.airvalet_admin_alerts for update;
  if a.verify_code_hash is null or a.verify_expires_at < now() or a.verify_attempts >= 5 then
    return jsonb_build_object('result', 'EXPIRED');
  end if;
  if extensions.digest(coalesce(p_code, '') || ':' || a.phone_e164, 'sha256') <> a.verify_code_hash then
    update public.airvalet_admin_alerts s set verify_attempts = s.verify_attempts + 1;
    return jsonb_build_object('result', 'WRONG_CODE');
  end if;
  update public.airvalet_admin_alerts s set phone_verified_at = now(), verify_code_hash = null, verify_expires_at = null, verify_attempts = 0;
  return jsonb_build_object('result', 'VERIFIED');
end $$;

-- ── Alert signals: inserted by triggers, consumed through Realtime ────────
create or replace function public.airvalet_alert_on_inbound()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.direction = 'inbound' and new.message_type = 'INBOUND' then
    insert into public.airvalet_alert_events (kind, ref_id) values ('GUEST_MESSAGE', new.id);
  end if;
  return null;
end $$;
create trigger airvalet_alert_inbound after insert on public.airvalet_sms_messages
  for each row execute function public.airvalet_alert_on_inbound();

create or replace function public.airvalet_alert_on_request()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.airvalet_alert_events (kind, ref_id) values ('PASS_REQUEST', new.id);
  return null;
end $$;
create trigger airvalet_alert_request after insert on public.airvalet_pass_requests
  for each row execute function public.airvalet_alert_on_request();

-- ── Realtime publication ──────────────────────────────────────────────────
-- passengers: activates the existing TV Mode channel (the 60-second polling
-- stays as the safety net). Requests + SMS messages: Inbox live updates.
-- RLS applies to every subscriber (TV_ONLY never receives passengers rows).
alter publication supabase_realtime add table public.passengers, public.airvalet_sms_messages,
  public.airvalet_pass_requests, public.airvalet_alert_events;

-- ── Function grants ───────────────────────────────────────────────────────
revoke all on function public.airvalet_portal_require_ops() from public, anon, authenticated;
revoke all on function public.airvalet_portal_require_admin() from public, anon, authenticated;
revoke all on function public.airvalet_is_super_admin() from public, anon;
revoke all on function public.airvalet_return_at(text, time) from public, anon, authenticated;
revoke all on function public.airvalet_portal_resolve(text, text) from public, anon, authenticated;
revoke all on function public.airvalet_portal_view(text, text) from public, anon, authenticated;
revoke all on function public.airvalet_portal_request(text, text, text, text, date, time, text, text, text) from public, anon, authenticated;
revoke all on function public.airvalet_pass_requests_list(integer) from public, anon;
revoke all on function public.airvalet_pass_request_decide(uuid, text, text, boolean) from public, anon;
revoke all on function public.airvalet_pass_state_get(bigint) from public, anon;
revoke all on function public.airvalet_pass_state_set(bigint, text, jsonb) from public, anon;
revoke all on function public.airvalet_portal_settings_get() from public, anon;
revoke all on function public.airvalet_portal_settings_set(jsonb) from public, anon;
revoke all on function public.airvalet_tv_alerts() from public, anon;
revoke all on function public.airvalet_push_subscribe(text, text, text, text, boolean) from public, anon;
revoke all on function public.airvalet_push_unsubscribe(text) from public, anon;
revoke all on function public.airvalet_push_targets() from public, anon, authenticated;
revoke all on function public.airvalet_push_result(uuid, boolean, boolean) from public, anon, authenticated;
revoke all on function public.airvalet_notify_claim(text, text) from public, anon, authenticated;
revoke all on function public.airvalet_notify_finish(text, text, integer, text, text) from public, anon, authenticated;
revoke all on function public.airvalet_admin_alert_target(text, bigint, text) from public, anon, authenticated;
revoke all on function public.airvalet_is_admin_alert_phone(text) from public, anon, authenticated;
revoke all on function public.airvalet_notify_details(text, uuid) from public, anon, authenticated;
revoke all on function public.airvalet_admin_alerts_get() from public, anon;
revoke all on function public.airvalet_admin_alerts_set(jsonb) from public, anon;
revoke all on function public.airvalet_admin_alerts_start_verify(uuid, text) from public, anon, authenticated;
revoke all on function public.airvalet_admin_alerts_confirm(text) from public, anon;
revoke all on function public.airvalet_alert_on_inbound() from public, anon, authenticated;
revoke all on function public.airvalet_alert_on_request() from public, anon, authenticated;

grant execute on function public.airvalet_is_super_admin() to authenticated;
grant execute on function public.airvalet_pass_requests_list(integer) to authenticated;
grant execute on function public.airvalet_pass_request_decide(uuid, text, text, boolean) to authenticated;
grant execute on function public.airvalet_pass_state_get(bigint) to authenticated;
grant execute on function public.airvalet_pass_state_set(bigint, text, jsonb) to authenticated;
grant execute on function public.airvalet_portal_settings_get() to authenticated;
grant execute on function public.airvalet_portal_settings_set(jsonb) to authenticated;
grant execute on function public.airvalet_tv_alerts() to authenticated;
grant execute on function public.airvalet_push_subscribe(text, text, text, text, boolean) to authenticated;
grant execute on function public.airvalet_push_unsubscribe(text) to authenticated;
grant execute on function public.airvalet_admin_alerts_get() to authenticated;
grant execute on function public.airvalet_admin_alerts_set(jsonb) to authenticated;
grant execute on function public.airvalet_admin_alerts_confirm(text) to authenticated;
grant execute on function public.airvalet_portal_view(text, text) to service_role;
grant execute on function public.airvalet_portal_request(text, text, text, text, date, time, text, text, text) to service_role;
grant execute on function public.airvalet_push_targets() to service_role;
grant execute on function public.airvalet_push_result(uuid, boolean, boolean) to service_role;
grant execute on function public.airvalet_notify_claim(text, text) to service_role;
grant execute on function public.airvalet_notify_finish(text, text, integer, text, text) to service_role;
grant execute on function public.airvalet_admin_alert_target(text, bigint, text) to service_role;
grant execute on function public.airvalet_is_admin_alert_phone(text) to service_role;
grant execute on function public.airvalet_notify_details(text, uuid) to service_role;
grant execute on function public.airvalet_admin_alerts_start_verify(uuid, text) to service_role;

commit;

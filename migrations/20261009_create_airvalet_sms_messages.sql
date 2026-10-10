-- AirValet SMS (Twilio) — message log, status audit trail, opt-outs, inbound.
--
-- LOCAL ONLY until the owner gives a separate GO for production.
-- Additive: creates new objects only; does not touch passengers or any
-- existing table, policy or function.
--
-- Security model:
--   * Every write goes through SECURITY DEFINER functions executable ONLY by
--     service_role (the send-sms / twilio-* Edge Functions). The browser can
--     never insert, update or delete SMS rows.
--   * Authenticated ops roles may READ the log/inbox (same role gate as
--     passengers). anon gets nothing.
--   * This project's default privileges grant anon/authenticated full table
--     rights and EXECUTE on new functions, so everything is revoked explicitly.
--   * No credential of any kind is stored here.

begin;

-- ── Phone normalization (mirrors normalizePhoneE164 in utils.js) ─────────
-- 10 digits → +1XXXXXXXXXX; 11 digits starting with 1 → +1…; leading '+'
-- with 8–15 digits → kept. Anything else → NULL (never guess a country code).
create or replace function public.airvalet_sms_normalize_phone(p_raw text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_raw is null or btrim(p_raw) = '' then null
    when left(btrim(p_raw), 1) = '+' then
      case when length(regexp_replace(p_raw, '\D', '', 'g')) between 8 and 15
                and left(regexp_replace(p_raw, '\D', '', 'g'), 1) <> '0'
           then '+' || regexp_replace(p_raw, '\D', '', 'g') end
    when length(regexp_replace(p_raw, '\D', '', 'g')) = 10 then
      '+1' || regexp_replace(p_raw, '\D', '', 'g')
    when length(regexp_replace(p_raw, '\D', '', 'g')) = 11
         and left(regexp_replace(p_raw, '\D', '', 'g'), 1) = '1' then
      '+' || regexp_replace(p_raw, '\D', '', 'g')
  end;
$$;

-- ── Messages (outbound + inbound) ─────────────────────────────────────────
create table public.airvalet_sms_messages (
  id                    uuid primary key default gen_random_uuid(),
  direction             text not null check (direction in ('outbound', 'inbound')),
  passenger_id          bigint references public.passengers(id) on delete set null,
  ticket_snapshot       text,
  phone_e164            text not null check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  message_type          text not null,
  template_key          text,
  template_version      text,
  body                  text,
  segments              integer,
  provider              text not null check (provider in ('twilio', 'mock')),
  provider_message_sid  text unique,
  messaging_service_sid text,
  status                text not null check (status in (
                          'pending', 'accepted', 'queued', 'sending', 'sent',
                          'delivered', 'undelivered', 'failed', 'send_unknown',
                          'blocked', 'received')),
  error_code            text,
  error_message         text,
  idempotency_key       text unique,
  attempt_count         integer not null default 0,
  sent_by               uuid,
  sent_by_name          text,          -- staff member picked in the UI (no individual logins)
  device_id             uuid,          -- approved device that sent it (airvalet_sms_devices)
  match_method          text check (match_method in (
                          'last_outbound', 'active_passenger', 'recent_outbound',
                          'ambiguous', 'unmatched', 'manual')),
  match_candidates      jsonb,
  read_at               timestamptz,   -- inbound only: first staff read
  read_by               uuid,
  assigned_by           uuid,          -- inbound only: manual passenger assignment
  assigned_at           timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  sent_at               timestamptz,
  delivered_at          timestamptz,
  failed_at             timestamptz,
  received_at           timestamptz,
  last_status_at        timestamptz,
  -- Staff alerts (unconfirmed sends, carrier blocks, failures) + resolution.
  attention             text check (attention in ('UNCONFIRMED', 'UNREACHABLE', 'CARRIER_FILTERED', 'FAILED')),
  attention_at          timestamptz,
  resolved_at           timestamptz,
  resolved_by           uuid,
  resolution            text check (resolution in ('confirmed_received', 'marked_not_sent', 'acknowledged')),
  constraint airvalet_sms_outbound_has_key
    check (direction = 'inbound' or idempotency_key is not null),
  constraint airvalet_sms_inbound_has_sid
    check (direction = 'outbound' or provider_message_sid is not null)
);

create index airvalet_sms_messages_passenger_idx on public.airvalet_sms_messages (passenger_id, created_at desc);
create index airvalet_sms_messages_phone_idx     on public.airvalet_sms_messages (phone_e164, created_at desc);
create index airvalet_sms_messages_status_idx    on public.airvalet_sms_messages (status) where direction = 'outbound';
create index airvalet_sms_messages_unread_idx    on public.airvalet_sms_messages (passenger_id) where direction = 'inbound' and read_at is null;
create index airvalet_sms_messages_device_idx    on public.airvalet_sms_messages (device_id, created_at desc) where direction = 'outbound';
create index airvalet_sms_messages_attention_idx on public.airvalet_sms_messages (attention_at desc) where attention is not null and resolved_at is null;

-- ── Status callback audit trail (every callback, even out-of-order/orphan) ─
create table public.airvalet_sms_status_events (
  id                   bigint generated always as identity primary key,
  provider_message_sid text not null,
  status               text not null,
  error_code           text,
  error_message        text,
  applied              boolean not null default false,
  received_at          timestamptz not null default now(),
  unique (provider_message_sid, status)
);

-- ── Opt-outs (STOP/START). Twilio Advanced Opt-Out also blocks at carrier
-- level; this table lets AirValet refuse before calling Twilio and audit it.
create table public.airvalet_sms_opt_outs (
  phone_e164   text primary key check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  opted_out    boolean not null,
  last_keyword text,
  source       text not null,
  updated_at   timestamptz not null default now()
);

-- ── SMS consent (A2P opt-in record). Append-only history per phone; the
-- latest row decides. Recorded by the attendant at check-in after the
-- passenger agrees (never pre-checked), or by a START keyword reply.
create table public.airvalet_sms_consents (
  id                 uuid primary key default gen_random_uuid(),
  seq                bigint generated always as identity unique, -- strict order (several rows can share now())
  phone_e164         text not null check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  passenger_id       bigint references public.passengers(id) on delete set null,
  status             text not null check (status in ('granted', 'revoked')),
  method             text not null check (method in ('checkin_attendant', 'keyword_start', 'keyword_stop', 'twilio_21610')),
  disclosure_version text,
  recorded_by        uuid,
  created_at         timestamptz not null default now()
);
create index airvalet_sms_consents_phone_idx on public.airvalet_sms_consents (phone_e164, seq desc);

-- ── Global switch + cost/volume caps + cutover + test mode (one row).
-- Starts PAUSED and in TEST MODE with no test numbers: nothing can be sent
-- until an ADMIN turns it on (airvalet_sms_set_settings) — independent of,
-- and in addition to, the AIRVALET_SMS_MODE server secret.
create table public.airvalet_sms_settings (
  id                   boolean primary key default true check (id),
  sending_enabled      boolean not null default false,
  -- Test mode: only these numbers can receive anything (owner's phone).
  test_only            boolean not null default true,
  test_phones          text[]  not null default '{}' check (cardinality(test_phones) <= 5),
  -- Cutover: only tickets checked in AFTER this point can join the Twilio
  -- program (id above cutover_after_id AND created after cutover_at). Old
  -- tickets stay on the iPhone/Customer Copy flow forever.
  cutover_at           timestamptz,
  cutover_after_id     bigint,
  max_per_phone_hour   integer not null default 4  check (max_per_phone_hour between 1 and 20),
  max_per_phone_day    integer not null default 10 check (max_per_phone_day between 1 and 50),
  max_per_device_hour  integer not null default 40 check (max_per_device_hour between 1 and 500),
  max_messages_day     integer not null default 300 check (max_messages_day between 1 and 5000),
  max_segments_day     integer not null default 600 check (max_segments_day between 1 and 10000),
  max_segments_message integer not null default 3  check (max_segments_message between 1 and 6),
  updated_at           timestamptz not null default now(),
  updated_by           uuid,
  check ((cutover_at is null) = (cutover_after_id is null))
);
insert into public.airvalet_sms_settings default values;

-- ── Authorized DEVICES (AirValet logins are per device and shared, e.g.
-- every phone uses "Admin"; the TV opens from the same session). Each
-- physical device keeps a random secret key (only its SHA-256 is stored);
-- an ADMIN approves it. Every send / check-in consent must present an
-- approved key — validated here on the server. The TV is never approved.
create table public.airvalet_sms_devices (
  id           uuid primary key default gen_random_uuid(),
  key_hash     bytea not null unique check (octet_length(key_hash) = 32),
  label        text not null check (length(btrim(label)) between 2 and 40),
  status       text not null default 'pending' check (status in ('pending', 'approved', 'revoked')),
  requested_by uuid,
  requested_at timestamptz not null default now(),
  user_agent   text,
  decided_by   uuid,
  decided_at   timestamptz,
  last_seen_at timestamptz
);

-- ── Tickets that belong to the Twilio program (created at check-in only).
-- No row → the ticket uses the old system (iPhone SMS) for its whole life.
create table public.airvalet_sms_enrollments (
  id           bigint generated always as identity primary key,
  passenger_id bigint unique references public.passengers(id) on delete set null,
  phone_e164   text not null check (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  device_id    uuid not null references public.airvalet_sms_devices(id),
  consent_id   uuid not null,
  staff_name   text,
  enrolled_at  timestamptz not null default now()
);
alter table public.airvalet_sms_messages      enable row level security;
alter table public.airvalet_sms_status_events enable row level security;
alter table public.airvalet_sms_opt_outs      enable row level security;
alter table public.airvalet_sms_consents      enable row level security;
alter table public.airvalet_sms_settings      enable row level security;
alter table public.airvalet_sms_devices       enable row level security;
alter table public.airvalet_sms_enrollments   enable row level security;

revoke all on public.airvalet_sms_messages      from public, anon, authenticated;
revoke all on public.airvalet_sms_status_events from public, anon, authenticated;
revoke all on public.airvalet_sms_opt_outs      from public, anon, authenticated;
revoke all on public.airvalet_sms_consents      from public, anon, authenticated;
revoke all on public.airvalet_sms_settings      from public, anon, authenticated;
revoke all on public.airvalet_sms_devices       from public, anon, authenticated;
revoke all on public.airvalet_sms_enrollments   from public, anon, authenticated;
revoke all on sequence public.airvalet_sms_enrollments_id_seq from public, anon, authenticated;
revoke all on sequence public.airvalet_sms_status_events_id_seq from public, anon, authenticated;
revoke all on sequence public.airvalet_sms_consents_seq_seq from public, anon, authenticated;
grant select on public.airvalet_sms_settings to authenticated;
-- Devices: ADMIN reads the list (never the hash); others use airvalet_sms_device_status().
grant select (id, label, status, requested_by, requested_at, user_agent, decided_by, decided_at, last_seen_at) on public.airvalet_sms_devices to authenticated;
grant select on public.airvalet_sms_enrollments to authenticated;
grant all on public.airvalet_sms_settings, public.airvalet_sms_devices, public.airvalet_sms_enrollments to service_role;
create policy airvalet_sms_settings_select_ops on public.airvalet_sms_settings
  for select to authenticated
  using (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]));
create policy airvalet_sms_devices_select_admin on public.airvalet_sms_devices
  for select to authenticated
  using (public.current_user_role() = 'ADMIN'::public.account_role);
create policy airvalet_sms_enrollments_select_ops on public.airvalet_sms_enrollments
  for select to authenticated
  using (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]));
grant select on public.airvalet_sms_messages to authenticated;
grant select on public.airvalet_sms_opt_outs to authenticated;
grant select on public.airvalet_sms_consents to authenticated;
grant all on public.airvalet_sms_messages, public.airvalet_sms_status_events, public.airvalet_sms_opt_outs, public.airvalet_sms_consents to service_role;

create policy airvalet_sms_consents_select_ops on public.airvalet_sms_consents
  for select to authenticated
  using (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]));

create policy airvalet_sms_messages_select_ops on public.airvalet_sms_messages
  for select to authenticated
  using (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]));
create policy airvalet_sms_opt_outs_select_ops on public.airvalet_sms_opt_outs
  for select to authenticated
  using (public.current_user_role() = any (array['ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER']::public.account_role[]));

-- ── Status ranking: transitions only move forward; terminal states stick ──
create or replace function public.airvalet_sms_status_rank(p_status text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case p_status
    when 'pending'      then 0
    when 'send_unknown' then 1
    when 'accepted'     then 2
    when 'queued'       then 3
    when 'sending'      then 4
    when 'sent'         then 5
    when 'undelivered'  then 9
    when 'failed'       then 9
    when 'delivered'    then 10
    else null
  end;
$$;

-- ── Consent: latest record for the phone decides ─────────────────────────
create or replace function public.airvalet_sms_has_consent(p_phone_e164 text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select c.status = 'granted' from public.airvalet_sms_consents c
                    where c.phone_e164 = p_phone_e164
                    order by c.seq desc limit 1), false);
$$;

-- ── Device key → SHA-256 (keys are 43–128 url-safe chars; anything else → null)
create or replace function public.airvalet_sms_device_key_hash(p_key text)
returns bytea
language sql
immutable
set search_path = ''
as $$
  select case when p_key ~ '^[A-Za-z0-9_-]{43,128}$' then extensions.digest(p_key, 'sha256') end;
$$;

-- ── Is this ticket allowed to JOIN the Twilio program (at check-in)? ─────
-- Only tickets created after the cutover (id AND time, both server-set),
-- still open, and only while the program is on.
create or replace function public.airvalet_sms_ticket_eligible(p_passenger_id bigint)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select s.sending_enabled and s.cutover_at is not null
           and p.id > s.cutover_after_id and p.created_at >= s.cutover_at
           and p.status in ('PENDING', 'NO DATE')
      from public.passengers p, public.airvalet_sms_settings s
     where p.id = p_passenger_id and s.id), false);
$$;

-- ── Claim: the ONLY way an outbound row is created ───────────────────────
-- Atomic duplicate prevention: the unique idempotency_key means a double
-- click / client retry / concurrent request gets the existing row back
-- (claimed = false) and must NOT call Twilio. Opt-out and rate limits are
-- checked under a per-phone advisory lock, so two racing requests cannot
-- both slip under the limit.
create or replace function public.airvalet_sms_claim(
  p_idempotency_key        text,
  p_passenger_id           bigint,
  p_ticket                 text,
  p_phone_e164             text,
  p_message_type           text,
  p_template_key           text,
  p_template_version       text,
  p_body                   text,
  p_segments               integer,
  p_provider               text,
  p_sent_by                uuid,
  p_max_per_phone_per_hour integer default null,  -- optional stricter caller cap
  p_max_per_phone_per_day  integer default null,  -- (airvalet_sms_settings always applies)
  p_sent_by_name           text default null,
  p_device_key_hash        bytea default null     -- SHA-256 of the sending device's key
)
returns table (message_id uuid, claimed boolean, status text, provider_message_sid text, error_code text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_existing public.airvalet_sms_messages%rowtype;
  v_set      public.airvalet_sms_settings%rowtype;
  v_block    text;
  v_id       uuid;
  v_ph_hour  integer;
  v_ph_day   integer;
  v_device   uuid;
begin
  if coalesce(btrim(p_idempotency_key), '') = '' then
    raise exception 'idempotency key required' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('airvalet_sms:' || p_phone_e164, 0));
  -- Global caps are evaluated under one more lock so concurrent senders
  -- cannot all slip under the daily total.
  perform pg_advisory_xact_lock(hashtextextended('airvalet_sms:global', 0));

  select * into v_existing from public.airvalet_sms_messages m
   where m.idempotency_key = p_idempotency_key;
  if found and v_existing.status = 'blocked' then
    -- A BLOCKED attempt never reached Twilio. Keep it as history under a
    -- retired key and let this request be evaluated again (e.g. START after
    -- STOP, or consent recorded later) instead of being refused forever.
    update public.airvalet_sms_messages m
       set idempotency_key = left(p_idempotency_key, 200) || ':blocked:' || m.id::text, updated_at = now()
     where m.id = v_existing.id;
  elsif found and v_existing.status = 'failed' and v_existing.resolution = 'marked_not_sent' then
    -- Staff confirmed an unconfirmed attempt never reached the passenger:
    -- retire it so the SAME message may be sent again (explicit human call).
    update public.airvalet_sms_messages m
       set idempotency_key = left(p_idempotency_key, 200) || ':notsent:' || m.id::text, updated_at = now()
     where m.id = v_existing.id;
  elsif found then
    return query select v_existing.id, false, v_existing.status, v_existing.provider_message_sid, v_existing.error_code;
    return;
  end if;

  select * into v_set from public.airvalet_sms_settings where id;
  v_ph_hour := least(coalesce(p_max_per_phone_per_hour, v_set.max_per_phone_hour), v_set.max_per_phone_hour);
  v_ph_day  := least(coalesce(p_max_per_phone_per_day,  v_set.max_per_phone_day),  v_set.max_per_phone_day);

  select d.id into v_device from public.airvalet_sms_devices d
   where p_device_key_hash is not null and d.key_hash = p_device_key_hash and d.status = 'approved';

  if not coalesce(v_set.sending_enabled, false) then
    v_block := 'SMS_PAUSED';
  elsif v_device is null then
    v_block := 'DEVICE_NOT_AUTHORIZED';
  elsif v_set.test_only and not (p_phone_e164 = any (v_set.test_phones)) then
    v_block := 'TEST_MODE_NUMBER';
  elsif p_passenger_id is null
        or not exists (select 1 from public.airvalet_sms_enrollments e where e.passenger_id = p_passenger_id) then
    -- Old / not-enrolled tickets never use Twilio (iPhone SMS instead).
    v_block := 'TICKET_NOT_ELIGIBLE';
  elsif exists (select 1 from public.airvalet_sms_opt_outs o
                 where o.phone_e164 = p_phone_e164 and o.opted_out) then
    v_block := 'OPTED_OUT';
  elsif not public.airvalet_sms_has_consent(p_phone_e164)
        and not (p_message_type = 'REPLY' and exists (
              select 1 from public.airvalet_sms_messages m
               where m.direction = 'inbound' and m.phone_e164 = p_phone_e164
                 and m.created_at > now() - interval '24 hours')) then
    -- No recorded opt-in. Exception: a staff REPLY within 24 h of the
    -- passenger texting us (conversational answer to their own message).
    v_block := 'NO_CONSENT';
  elsif coalesce(p_segments, 1) > v_set.max_segments_message then
    v_block := 'TOO_LONG';
  elsif exists (select 1 from public.airvalet_sms_messages m
                 where m.direction = 'outbound' and m.phone_e164 = p_phone_e164
                   and m.message_type = p_message_type
                   and (p_message_type <> 'REPLY' or m.body is not distinct from p_body)
                   and m.status in ('pending', 'send_unknown') and m.resolved_at is null
                   and m.created_at > now() - interval '7 days') then
    -- The same kind of text (for a REPLY: the same words) to this phone is
    -- still in flight or UNCONFIRMED (timeout / crash): it may have been
    -- delivered. Staff must check and resolve it (airvalet_sms_resolve_alert)
    -- before it can go out again. Different replies are not held up.
    v_block := 'PREVIOUS_UNCONFIRMED';
  elsif exists (select 1 from public.airvalet_sms_messages m
                 where m.direction = 'outbound' and m.phone_e164 = p_phone_e164
                   and m.message_type = p_message_type
                   and m.status not in ('blocked', 'failed', 'undelivered')
                   and m.created_at > now() - interval '2 minutes'
                   and (case when p_message_type = 'REPLY' then m.body is not distinct from p_body
                             else m.template_key is not distinct from p_template_key end)) then
    -- Same text (REPLY) or same template (e.g. the same pickup place) to the
    -- same phone < 2 min ago: a second tap / second device / new draft id.
    -- A CORRECTED template (Hangar 19 → Customs) is a different text: allowed.
    v_block := 'DUPLICATE_RECENT';
  elsif (select count(*) from public.airvalet_sms_messages m
          where m.direction = 'outbound' and m.phone_e164 = p_phone_e164
            and m.status <> 'blocked' and m.created_at > now() - interval '1 hour') >= v_ph_hour then
    v_block := 'RATE_LIMIT_HOUR';
  elsif (select count(*) from public.airvalet_sms_messages m
          where m.direction = 'outbound' and m.phone_e164 = p_phone_e164
            and m.status <> 'blocked' and m.created_at > now() - interval '24 hours') >= v_ph_day then
    v_block := 'RATE_LIMIT_DAY';
  elsif (select count(*) from public.airvalet_sms_messages m
          where m.direction = 'outbound' and m.device_id = v_device
            and m.status <> 'blocked' and m.created_at > now() - interval '1 hour') >= v_set.max_per_device_hour then
    v_block := 'DEVICE_RATE_LIMIT';
  elsif (select count(*) >= v_set.max_messages_day or coalesce(sum(m.segments), 0) + coalesce(p_segments, 1) > v_set.max_segments_day
           from public.airvalet_sms_messages m
          where m.direction = 'outbound' and m.status <> 'blocked'
            and m.created_at > now() - interval '24 hours') then
    v_block := 'DAILY_CAP';
  end if;

  insert into public.airvalet_sms_messages as m (
    direction, passenger_id, ticket_snapshot, phone_e164, message_type, template_key,
    template_version, body, segments, provider, status, error_code, idempotency_key,
    sent_by, sent_by_name, device_id, failed_at)
  values (
    'outbound', p_passenger_id, p_ticket, p_phone_e164, p_message_type, p_template_key,
    p_template_version, p_body, p_segments, p_provider,
    case when v_block is null then 'pending' else 'blocked' end, v_block, p_idempotency_key,
    p_sent_by, left(p_sent_by_name, 80), v_device, case when v_block is null then null else now() end)
  returning m.id into v_id;

  return query select v_id, v_block is null,
                      case when v_block is null then 'pending' else 'blocked' end,
                      null::text, v_block;
end;
$$;

-- ── Apply a status to a row (shared by send result + callbacks) ──────────
create or replace function public.airvalet_sms_apply_status_row(
  p_id uuid, p_status text, p_error_code text, p_error_message text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cur  text;
  v_rank integer := public.airvalet_sms_status_rank(p_status);
begin
  if v_rank is null then
    return false;
  end if;
  select m.status into v_cur from public.airvalet_sms_messages m where m.id = p_id for update;
  if v_cur is null or v_cur in ('blocked', 'received')
     or public.airvalet_sms_status_rank(v_cur) >= 9
     or public.airvalet_sms_status_rank(v_cur) >= v_rank then
    return false;
  end if;
  update public.airvalet_sms_messages m
     set status         = p_status,
         error_code     = coalesce(p_error_code, m.error_code),
         error_message  = coalesce(p_error_message, m.error_message),
         sent_at        = case when p_status in ('sent', 'delivered') then coalesce(m.sent_at, now()) else m.sent_at end,
         delivered_at   = case when p_status = 'delivered' then now() else m.delivered_at end,
         failed_at      = case when p_status in ('failed', 'undelivered') then now() else m.failed_at end,
         last_status_at = now(),
         updated_at     = now(),
         -- Alerts: carrier outcomes staff should see; an unconfirmed send that
         -- now has a real status is no longer "unconfirmed".
         attention      = case
                            when p_status in ('failed', 'undelivered') then
                              case when p_error_code in ('30003', '30005', '30006') then 'UNREACHABLE'
                                   when p_error_code = '30007' then 'CARRIER_FILTERED'
                                   else 'FAILED' end
                            when m.attention = 'UNCONFIRMED' then null
                            else m.attention end,
         attention_at   = case
                            when p_status in ('failed', 'undelivered') then now()
                            when m.attention = 'UNCONFIRMED' then null
                            else m.attention_at end
   where m.id = p_id;
  return true;
end;
$$;

-- ── Record the provider's answer to our send request ─────────────────────
-- Only moves a row out of 'pending'/'send_unknown'. Afterwards replays any
-- status callback that arrived BEFORE this call stored the SID (callbacks
-- can beat the HTTP response).
create or replace function public.airvalet_sms_mark_result(
  p_message_id            uuid,
  p_status                text,
  p_provider_message_sid  text,
  p_messaging_service_sid text,
  p_error_code            text,
  p_error_message         text,
  p_attempts              integer)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cur text;
  v_ev  record;
begin
  if p_status not in ('accepted', 'queued', 'sending', 'sent', 'failed', 'send_unknown') then
    raise exception 'invalid send result status %', p_status using errcode = '22023';
  end if;
  if p_provider_message_sid is not null then
    perform pg_advisory_xact_lock(hashtextextended('airvalet_sms_sid:' || p_provider_message_sid, 0));
  end if;
  select m.status into v_cur from public.airvalet_sms_messages m where m.id = p_message_id for update;
  if v_cur is null then
    raise exception 'message % not found', p_message_id using errcode = 'P0002';
  end if;
  if v_cur not in ('pending', 'send_unknown') then
    return v_cur;
  end if;
  update public.airvalet_sms_messages m
     set status                = p_status,
         provider_message_sid  = coalesce(p_provider_message_sid, m.provider_message_sid),
         messaging_service_sid = coalesce(p_messaging_service_sid, m.messaging_service_sid),
         error_code            = p_error_code,
         error_message         = p_error_message,
         attempt_count         = coalesce(p_attempts, m.attempt_count),
         failed_at             = case when p_status = 'failed' then now() else m.failed_at end,
         sent_at               = case when p_status = 'sent' then coalesce(m.sent_at, now()) else m.sent_at end,
         last_status_at        = now(),
         updated_at            = now(),
         attention             = case when p_status = 'send_unknown' then 'UNCONFIRMED' else m.attention end,
         attention_at          = case when p_status = 'send_unknown' then now() else m.attention_at end
   where m.id = p_message_id;

  if p_provider_message_sid is not null then
    for v_ev in
      select e.id, e.status, e.error_code, e.error_message
        from public.airvalet_sms_status_events e
       where e.provider_message_sid = p_provider_message_sid
       order by public.airvalet_sms_status_rank(e.status), e.id
    loop
      if public.airvalet_sms_apply_status_row(p_message_id, v_ev.status, v_ev.error_code, v_ev.error_message) then
        update public.airvalet_sms_status_events set applied = true where id = v_ev.id;
      end if;
    end loop;
  end if;

  return (select m.status from public.airvalet_sms_messages m where m.id = p_message_id);
end;
$$;

-- ── Twilio status callback ───────────────────────────────────────────────
-- Always records the event (audit trail, dedup on sid+status). Applies it
-- only as a forward transition. Unknown SID → kept as orphan; replayed by
-- airvalet_sms_mark_result once the SID is known.
create or replace function public.airvalet_sms_apply_status(
  p_provider_message_sid text, p_status text, p_error_code text, p_error_message text,
  p_message_id uuid default null)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event_id bigint;
  v_msg_id   uuid;
begin
  if public.airvalet_sms_status_rank(p_status) is null or p_status in ('pending', 'send_unknown') then
    return 'ignored_status';
  end if;
  -- Serialized with airvalet_sms_mark_result for the same SID (no lost update).
  perform pg_advisory_xact_lock(hashtextextended('airvalet_sms_sid:' || p_provider_message_sid, 0));

  insert into public.airvalet_sms_status_events (provider_message_sid, status, error_code, error_message)
  values (p_provider_message_sid, p_status, p_error_code, p_error_message)
  on conflict (provider_message_sid, status) do nothing
  returning id into v_event_id;
  if v_event_id is null then
    return 'duplicate';
  end if;

  select m.id into v_msg_id from public.airvalet_sms_messages m
   where m.provider_message_sid = p_provider_message_sid and m.direction = 'outbound';
  if v_msg_id is null and p_message_id is not null then
    -- Our send never learned the SID (timeout → send_unknown) but Twilio did
    -- create the message: the StatusCallback URL carries our message id
    -- (?mid=, covered by the Twilio signature). Adopt the SID now.
    update public.airvalet_sms_messages m
       set provider_message_sid = p_provider_message_sid, updated_at = now()
     where m.id = p_message_id and m.direction = 'outbound'
       and m.provider_message_sid is null and m.status in ('pending', 'send_unknown')
    returning m.id into v_msg_id;
  end if;
  if v_msg_id is null then
    return 'orphan';
  end if;

  if public.airvalet_sms_apply_status_row(v_msg_id, p_status, p_error_code, p_error_message) then
    update public.airvalet_sms_status_events set applied = true where id = v_event_id;
    return 'applied';
  end if;
  return 'stale';
end;
$$;

-- ── Reconciliation: sends that never got an answer ───────────────────────
-- pending / send_unknown with no SID after p_minutes → alert UNCONFIRMED.
-- Called by every send-sms invocation and every inbox load (cheap, indexed,
-- idempotent). A later status callback (via ?mid=) clears the alert.
create or replace function public.airvalet_sms_reconcile(p_minutes integer default 10)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare v_n integer;
begin
  -- send-sms (service_role), direct DB admin, or ops staff (inbox load).
  if coalesce(auth.role(), '') <> 'service_role'
     and not (auth.uid() is null and session_user in ('postgres', 'supabase_admin')) then
    perform public.airvalet_sms_require_ops();
  end if;
  update public.airvalet_sms_messages m
     set status = 'send_unknown',
         attention = 'UNCONFIRMED', attention_at = now(), updated_at = now(),
         error_code = coalesce(m.error_code, 'NO_PROVIDER_ANSWER')
   where m.direction = 'outbound' and m.status in ('pending', 'send_unknown')
     and m.provider_message_sid is null and m.attention is null and m.resolved_at is null
     and m.created_at < now() - make_interval(mins => greatest(p_minutes, 2));
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ── Inbound matching: phone + conversation context, never ticket alone ───
-- 1. last outbound to this phone within 72 h (they are replying to it);
-- 2. else exactly one ACTIVE passenger (PENDING / NO DATE) with this phone;
-- 3. else last outbound within 14 days;
-- 4. else several active passengers → 'ambiguous' (candidates kept, staff assigns);
-- 5. else 'unmatched'.
create or replace function public.airvalet_sms_match_passenger(p_phone_e164 text)
returns table (passenger_id bigint, match_method text, candidates jsonb)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_last   record;
  v_active bigint[];
begin
  select m.passenger_id, m.created_at into v_last
    from public.airvalet_sms_messages m
   where m.direction = 'outbound' and m.phone_e164 = p_phone_e164
     and m.passenger_id is not null and m.status <> 'blocked'
   order by m.created_at desc limit 1;

  select coalesce(array_agg(p.id order by p.id desc), '{}') into v_active
    from public.passengers p
   where public.airvalet_sms_normalize_phone(p.phone) = p_phone_e164
     and p.status in ('PENDING', 'NO DATE');

  if v_last.passenger_id is not null and v_last.created_at > now() - interval '72 hours' then
    return query select v_last.passenger_id, 'last_outbound'::text, to_jsonb(v_active);
  elsif cardinality(v_active) = 1 then
    return query select v_active[1], 'active_passenger'::text, to_jsonb(v_active);
  elsif v_last.passenger_id is not null and v_last.created_at > now() - interval '14 days' then
    return query select v_last.passenger_id, 'recent_outbound'::text, to_jsonb(v_active);
  elsif cardinality(v_active) > 1 then
    return query select null::bigint, 'ambiguous'::text, to_jsonb(v_active);
  else
    return query select null::bigint, 'unmatched'::text, to_jsonb(v_active);
  end if;
end;
$$;

-- ── Inbound SMS (idempotent on Twilio MessageSid) ────────────────────────
-- p_keyword: 'STOP' | 'START' | 'HELP' | null (classified by the Edge
-- Function from Twilio's OptOutType or the standard keyword list).
create or replace function public.airvalet_sms_record_inbound(
  p_provider_message_sid  text,
  p_from_e164             text,
  p_body                  text,
  p_messaging_service_sid text,
  p_keyword               text)
returns table (message_id uuid, inserted boolean, passenger_id bigint, match_method text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_match record;
  v_id    uuid;
begin
  if exists (select 1 from public.airvalet_sms_messages m
              where m.provider_message_sid = p_provider_message_sid) then
    return query select m.id, false, m.passenger_id, m.match_method
                   from public.airvalet_sms_messages m where m.provider_message_sid = p_provider_message_sid;
    return;
  end if;

  select * into v_match from public.airvalet_sms_match_passenger(p_from_e164);

  insert into public.airvalet_sms_messages as m (
    direction, passenger_id, ticket_snapshot, phone_e164, message_type, body, provider,
    provider_message_sid, messaging_service_sid, status, match_method, match_candidates, received_at)
  values (
    'inbound', v_match.passenger_id,
    (select p.ticket from public.passengers p where p.id = v_match.passenger_id),
    p_from_e164, coalesce('INBOUND_' || p_keyword, 'INBOUND'), p_body, 'twilio',
    p_provider_message_sid, p_messaging_service_sid, 'received', v_match.match_method,
    v_match.candidates, now())
  on conflict (provider_message_sid) do nothing
  returning m.id into v_id;

  if v_id is null then
    return query select m.id, false, m.passenger_id, m.match_method
                   from public.airvalet_sms_messages m where m.provider_message_sid = p_provider_message_sid;
    return;
  end if;

  if p_keyword in ('STOP', 'START') then
    -- Same per-phone lock as airvalet_sms_claim: a STOP waits for (and then
    -- blocks) any send being claimed for this phone at the same moment.
    perform pg_advisory_xact_lock(hashtextextended('airvalet_sms:' || p_from_e164, 0));
    insert into public.airvalet_sms_opt_outs as o (phone_e164, opted_out, last_keyword, source, updated_at)
    values (p_from_e164, p_keyword = 'STOP', p_keyword, 'inbound_sms', now())
    on conflict (phone_e164) do update
      set opted_out = excluded.opted_out, last_keyword = excluded.last_keyword,
          source = excluded.source, updated_at = now();
    -- START/UNSTOP (exact keyword, classified by the Edge Function — never a
    -- conversational "yes") is an affirmative opt-in; STOP revokes.
    insert into public.airvalet_sms_consents (phone_e164, passenger_id, status, method)
    values (p_from_e164, v_match.passenger_id,
            case when p_keyword = 'START' then 'granted' else 'revoked' end,
            case when p_keyword = 'START' then 'keyword_start' else 'keyword_stop' end);
  end if;

  return query select v_id, true, v_match.passenger_id, v_match.match_method;
end;
$$;

-- Twilio error 21610 = recipient replied STOP → keep our opt-out list in sync.
create or replace function public.airvalet_sms_mark_opted_out(p_phone_e164 text, p_source text)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.airvalet_sms_opt_outs as o (phone_e164, opted_out, last_keyword, source, updated_at)
  values (p_phone_e164, true, null, p_source, now())
  on conflict (phone_e164) do update
    set opted_out = true, source = excluded.source, updated_at = now();
  insert into public.airvalet_sms_consents (phone_e164, status, method)
  values (p_phone_e164, 'revoked', 'twilio_21610');
$$;

-- ═══ Staff-facing (authenticated) — inbox + consent ══════════════════════
-- Callable from the AirValet browser with the user's JWT. Each one checks
-- the ops role itself (SECURITY DEFINER) and touches only its own columns.

create or replace function public.airvalet_sms_require_ops()
returns public.account_role
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_role public.account_role := public.current_user_role();
begin
  if v_role is null or v_role not in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER') then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return v_role;
end;
$$;

-- Check-in opt-in + enrollment into the Twilio program. Server-side rules:
-- approved device (key), program on, ticket eligible (created after the
-- cutover), within 2 hours of check-in. The phone always comes from the
-- passengers row. When any rule fails NOTHING is recorded and the ticket
-- stays on the old (iPhone SMS) system — the reason is returned for the UI.
create or replace function public.airvalet_sms_record_consent(
  p_passenger_id bigint, p_disclosure_version text, p_device_key text, p_staff_name text default null)
returns table (enrolled boolean, reason text, consent_id uuid, phone_e164 text, opted_out boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_phone  text;
  v_device uuid;
  v_id     uuid;
  v_pax    public.passengers%rowtype;
begin
  perform public.airvalet_sms_require_ops();
  if coalesce(btrim(p_disclosure_version), '') = '' then
    raise exception 'disclosure version required' using errcode = '22023';
  end if;
  select d.id into v_device from public.airvalet_sms_devices d
   where d.key_hash = public.airvalet_sms_device_key_hash(p_device_key) and d.status = 'approved';
  select * into v_pax from public.passengers p where p.id = p_passenger_id for update;
  if not found then
    return query select false, 'PASSENGER_NOT_FOUND'::text, null::uuid, null::text, null::boolean; return;
  end if;
  v_phone := public.airvalet_sms_normalize_phone(v_pax.phone);
  if v_device is null then
    return query select false, 'DEVICE_NOT_AUTHORIZED'::text, null::uuid, v_phone, null::boolean; return;
  elsif exists (select 1 from public.airvalet_sms_enrollments e where e.passenger_id = p_passenger_id) then
    return query select true, 'ALREADY_ENROLLED'::text, (select e.consent_id from public.airvalet_sms_enrollments e where e.passenger_id = p_passenger_id), v_phone,
      coalesce((select o.opted_out from public.airvalet_sms_opt_outs o where o.phone_e164 = v_phone), false); return;
  elsif not public.airvalet_sms_ticket_eligible(p_passenger_id) then
    return query select false, 'TICKET_NOT_ELIGIBLE'::text, null::uuid, v_phone, null::boolean; return;
  elsif v_pax.created_at < now() - interval '2 hours' then
    return query select false, 'CHECKIN_WINDOW_CLOSED'::text, null::uuid, v_phone, null::boolean; return;
  elsif v_phone is null then
    return query select false, 'INVALID_PHONE'::text, null::uuid, null::text, null::boolean; return;
  end if;
  insert into public.airvalet_sms_consents (phone_e164, passenger_id, status, method, disclosure_version, recorded_by)
  values (v_phone, p_passenger_id, 'granted', 'checkin_attendant', left(p_disclosure_version, 40), auth.uid())
  returning id into v_id;
  insert into public.airvalet_sms_enrollments (passenger_id, phone_e164, device_id, consent_id, staff_name)
  values (p_passenger_id, v_phone, v_device, v_id, left(btrim(p_staff_name), 60));
  update public.airvalet_sms_devices d set last_seen_at = now() where d.id = v_device;
  -- A previous STOP stays in force until the passenger texts START.
  return query select true, 'ENROLLED'::text, v_id, v_phone,
    coalesce((select o.opted_out from public.airvalet_sms_opt_outs o where o.phone_e164 = v_phone), false);
end;
$$;

create or replace function public.airvalet_sms_mark_read(p_passenger_id bigint default null, p_message_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare v_n integer;
begin
  perform public.airvalet_sms_require_ops();
  if p_passenger_id is null and p_message_id is null then
    raise exception 'passenger or message required' using errcode = '22023';
  end if;
  update public.airvalet_sms_messages m
     set read_at = now(), read_by = auth.uid(), updated_at = now()
   where m.direction = 'inbound' and m.read_at is null
     and ((p_passenger_id is not null and m.passenger_id = p_passenger_id)
       or (p_message_id is not null and m.id = p_message_id));
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- Review queue: link an ambiguous/unmatched inbound to a passenger. Only a
-- passenger whose phone IS the sender's number (so a reply goes back to the
-- same phone). Re-assigning an already linked message: ADMIN/MANAGER only.
create or replace function public.airvalet_sms_assign_inbound(p_message_id uuid, p_passenger_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.account_role := public.airvalet_sms_require_ops();
  v_msg  public.airvalet_sms_messages%rowtype;
  v_pax  record;
begin
  select * into v_msg from public.airvalet_sms_messages m where m.id = p_message_id for update;
  if not found or v_msg.direction <> 'inbound' then
    raise exception 'inbound message not found' using errcode = 'P0002';
  end if;
  if v_msg.passenger_id is not null and v_role not in ('ADMIN', 'MANAGER') then
    raise exception 'already assigned' using errcode = '42501';
  end if;
  select p.id, p.ticket, public.airvalet_sms_normalize_phone(p.phone) as e164 into v_pax
    from public.passengers p where p.id = p_passenger_id;
  if v_pax.id is null then
    raise exception 'passenger not found' using errcode = 'P0002';
  end if;
  if v_pax.e164 is distinct from v_msg.phone_e164 then
    raise exception 'passenger phone does not match sender' using errcode = '22023';
  end if;
  update public.airvalet_sms_messages m
     set passenger_id = v_pax.id, ticket_snapshot = v_pax.ticket, match_method = 'manual',
         assigned_by = auth.uid(), assigned_at = now(), updated_at = now()
   where m.id = p_message_id;
end;
$$;

-- ── Alerts: staff resolve an unconfirmed / failed send ───────────────────
-- 'confirmed_received': passenger confirms they got it (no resend).
-- 'marked_not_sent'  : passenger did NOT get it → the same message may be
--                      sent again (claim retires the old key).
-- 'acknowledged'     : carrier failure seen, nothing else to do.
create or replace function public.airvalet_sms_resolve_alert(p_message_id uuid, p_resolution text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare v_msg public.airvalet_sms_messages%rowtype;
begin
  perform public.airvalet_sms_require_ops();
  if p_resolution not in ('confirmed_received', 'marked_not_sent', 'acknowledged') then
    raise exception 'invalid resolution' using errcode = '22023';
  end if;
  select * into v_msg from public.airvalet_sms_messages m where m.id = p_message_id for update;
  if not found or v_msg.direction <> 'outbound' or v_msg.attention is null or v_msg.resolved_at is not null then
    raise exception 'no open alert for this message' using errcode = 'P0002';
  end if;
  if p_resolution = 'marked_not_sent' and v_msg.status not in ('pending', 'send_unknown') then
    raise exception 'only an unconfirmed send can be marked as not sent' using errcode = '22023';
  end if;
  update public.airvalet_sms_messages m
     set resolved_at = now(), resolved_by = auth.uid(), resolution = p_resolution, updated_at = now(),
         status = case when p_resolution = 'marked_not_sent' then 'failed' else m.status end,
         failed_at = case when p_resolution = 'marked_not_sent' then now() else m.failed_at end,
         error_code = case when p_resolution = 'marked_not_sent' then 'STAFF_MARKED_NOT_SENT' else m.error_code end
   where m.id = p_message_id;
  return p_resolution;
end;
$$;

-- ── Devices: request (any ops device), status (app start), decide (ADMIN) ─
create or replace function public.airvalet_sms_device_request(p_device_key text, p_label text, p_user_agent text default null)
returns table (device_id uuid, status text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_hash bytea := public.airvalet_sms_device_key_hash(p_device_key);
begin
  perform public.airvalet_sms_require_ops();   -- TV_ONLY / no role → refused
  if v_hash is null then raise exception 'invalid device key' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_label, ''))) not between 2 and 40 then raise exception 'device name 2-40 chars' using errcode = '22023'; end if;
  insert into public.airvalet_sms_devices as d (key_hash, label, requested_by, user_agent)
  values (v_hash, btrim(p_label), auth.uid(), left(p_user_agent, 160))
  on conflict (key_hash) do nothing;
  return query select d.id, d.status from public.airvalet_sms_devices d where d.key_hash = v_hash;
end;
$$;

-- What the app needs at start: is THIS device approved, is the program on,
-- test mode, cutover. Unknown key → status 'unknown'. Never reveals others.
create or replace function public.airvalet_sms_device_status(p_device_key text)
returns table (device_id uuid, label text, status text, sending_enabled boolean, test_only boolean, cutover_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dev public.airvalet_sms_devices%rowtype;
  v_set public.airvalet_sms_settings%rowtype;
begin
  perform public.airvalet_sms_require_ops();
  select * into v_set from public.airvalet_sms_settings s where s.id;
  select * into v_dev from public.airvalet_sms_devices d where d.key_hash = public.airvalet_sms_device_key_hash(p_device_key);
  if found then
    update public.airvalet_sms_devices d set last_seen_at = now() where d.id = v_dev.id;
  end if;
  return query select v_dev.id, v_dev.label, coalesce(v_dev.status, 'unknown'), v_set.sending_enabled, v_set.test_only, v_set.cutover_at;
end;
$$;

create or replace function public.airvalet_sms_device_decide(p_device_id uuid, p_status text, p_label text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.current_user_role() is distinct from 'ADMIN'::public.account_role then
    raise exception 'ADMIN only' using errcode = '42501';
  end if;
  if p_status not in ('approved', 'revoked') then raise exception 'status must be approved or revoked' using errcode = '22023'; end if;
  update public.airvalet_sms_devices d
     set status = p_status, decided_by = auth.uid(), decided_at = now(),
         label = coalesce(nullif(btrim(p_label), ''), d.label)
   where d.id = p_device_id;
  if not found then raise exception 'device not found' using errcode = 'P0002'; end if;
end;
$$;

-- ── Settings (ADMIN). Test phones are validated as E.164 (max 5). ────────
create or replace function public.airvalet_sms_set_settings(
  p_sending_enabled boolean default null, p_test_only boolean default null, p_test_phones text[] default null,
  p_max_per_phone_hour integer default null, p_max_per_phone_day integer default null,
  p_max_per_device_hour integer default null, p_max_messages_day integer default null,
  p_max_segments_day integer default null, p_max_segments_message integer default null)
returns public.airvalet_sms_settings
language plpgsql
security definer
set search_path = ''
as $$
declare v public.airvalet_sms_settings%rowtype;
begin
  if public.current_user_role() is distinct from 'ADMIN'::public.account_role then
    raise exception 'ADMIN only' using errcode = '42501';
  end if;
  if p_test_phones is not null and exists (select 1 from unnest(p_test_phones) x where x !~ '^\+1[2-9][0-9]{9}$') then
    raise exception 'test phones must be US E.164 (+1XXXXXXXXXX)' using errcode = '22023';
  end if;
  update public.airvalet_sms_settings s
     set sending_enabled      = coalesce(p_sending_enabled, s.sending_enabled),
         test_only            = coalesce(p_test_only, s.test_only),
         test_phones          = coalesce(p_test_phones, s.test_phones),
         max_per_phone_hour   = coalesce(p_max_per_phone_hour, s.max_per_phone_hour),
         max_per_phone_day    = coalesce(p_max_per_phone_day, s.max_per_phone_day),
         max_per_device_hour  = coalesce(p_max_per_device_hour, s.max_per_device_hour),
         max_messages_day     = coalesce(p_max_messages_day, s.max_messages_day),
         max_segments_day     = coalesce(p_max_segments_day, s.max_segments_day),
         max_segments_message = coalesce(p_max_segments_message, s.max_segments_message),
         updated_at = now(), updated_by = auth.uid()
   where s.id
  returning * into v;
  return v;
end;
$$;

-- ── Cutover (ADMIN, explicit phrase). From this moment only NEW check-ins
-- can join the Twilio program. 'STOP' closes it again (already-enrolled
-- tickets keep their history; nothing is converted either way).
create or replace function public.airvalet_sms_set_cutover(p_confirm text)
returns public.airvalet_sms_settings
language plpgsql
security definer
set search_path = ''
as $$
declare v public.airvalet_sms_settings%rowtype;
begin
  if public.current_user_role() is distinct from 'ADMIN'::public.account_role then
    raise exception 'ADMIN only' using errcode = '42501';
  end if;
  if p_confirm = 'START NEW CHECK-INS' then
    update public.airvalet_sms_settings s
       set cutover_at = now(), cutover_after_id = coalesce((select max(p.id) from public.passengers p), 0),
           updated_at = now(), updated_by = auth.uid()
     where s.id and s.cutover_at is null
    returning * into v;
    if not found then raise exception 'cutover already set' using errcode = '22023'; end if;
  elsif p_confirm = 'STOP NEW CHECK-INS' then
    update public.airvalet_sms_settings s
       set cutover_at = null, cutover_after_id = null, updated_at = now(), updated_by = auth.uid()
     where s.id returning * into v;
  else
    raise exception 'confirmation phrase required' using errcode = '22023';
  end if;
  return v;
end;
$$;

-- ── Inbox views (security_invoker → the caller's RLS applies) ────────────
create view public.airvalet_sms_conversations with (security_invoker = true) as
select
  m.passenger_id,
  p.name                 as passenger_name,
  p.ticket,
  p.status               as passenger_status,
  last.phone_e164,
  last.created_at        as last_message_at,
  last.direction         as last_direction,
  left(last.body, 140)   as last_body,
  last.status            as last_status,
  count(*) filter (where m.direction = 'inbound' and m.read_at is null) as unread_count,
  coalesce(oo.opted_out, false) as opted_out,
  coalesce(cs.status = 'granted', false) as has_consent
from public.airvalet_sms_messages m
join public.passengers p on p.id = m.passenger_id
cross join lateral (
  select x.phone_e164, x.created_at, x.direction, x.body, x.status
    from public.airvalet_sms_messages x
   where x.passenger_id = m.passenger_id and x.status <> 'blocked'
   order by x.created_at desc limit 1) last
left join public.airvalet_sms_opt_outs oo on oo.phone_e164 = last.phone_e164
left join lateral (
  select c.status from public.airvalet_sms_consents c
   where c.phone_e164 = last.phone_e164 order by c.seq desc limit 1) cs on true
where m.passenger_id is not null
group by m.passenger_id, p.name, p.ticket, p.status, last.phone_e164, last.created_at,
         last.direction, last.body, last.status, oo.opted_out, cs.status;

create view public.airvalet_sms_review_queue with (security_invoker = true) as
select m.id, m.phone_e164, m.body, m.received_at, m.match_method, m.match_candidates, m.read_at, m.message_type
  from public.airvalet_sms_messages m
 where m.direction = 'inbound' and m.passenger_id is null
 order by m.received_at desc;

create view public.airvalet_sms_alerts with (security_invoker = true) as
select m.id, m.passenger_id, p.name as passenger_name, m.ticket_snapshot, m.phone_e164, m.message_type,
       m.status, m.attention, m.attention_at, m.error_code, m.created_at, m.sent_by_name
  from public.airvalet_sms_messages m
  left join public.passengers p on p.id = m.passenger_id
 where m.direction = 'outbound' and m.attention is not null and m.resolved_at is null
 order by m.attention_at desc;

revoke all on public.airvalet_sms_conversations, public.airvalet_sms_review_queue, public.airvalet_sms_alerts from public, anon, authenticated;
grant select on public.airvalet_sms_conversations, public.airvalet_sms_review_queue, public.airvalet_sms_alerts to authenticated, service_role;

revoke all on function public.airvalet_sms_require_ops() from public, anon, authenticated;
revoke all on function public.airvalet_sms_has_consent(text) from public, anon, authenticated;
revoke all on function public.airvalet_sms_record_consent(bigint, text, text, text) from public, anon;
revoke all on function public.airvalet_sms_mark_read(bigint, uuid) from public, anon;
revoke all on function public.airvalet_sms_assign_inbound(uuid, bigint) from public, anon;
grant execute on function public.airvalet_sms_record_consent(bigint, text, text, text) to authenticated;
grant execute on function public.airvalet_sms_mark_read(bigint, uuid) to authenticated;
grant execute on function public.airvalet_sms_assign_inbound(uuid, bigint) to authenticated;
grant execute on function public.airvalet_sms_has_consent(text) to service_role;
revoke all on function public.airvalet_sms_resolve_alert(uuid, text) from public, anon;
revoke all on function public.airvalet_sms_device_request(text, text, text) from public, anon;
revoke all on function public.airvalet_sms_device_status(text) from public, anon;
revoke all on function public.airvalet_sms_device_decide(uuid, text, text) from public, anon;
revoke all on function public.airvalet_sms_set_settings(boolean, boolean, text[], integer, integer, integer, integer, integer, integer) from public, anon;
revoke all on function public.airvalet_sms_set_cutover(text) from public, anon;
revoke all on function public.airvalet_sms_device_key_hash(text) from public, anon, authenticated;
revoke all on function public.airvalet_sms_ticket_eligible(bigint) from public, anon, authenticated;
grant execute on function public.airvalet_sms_device_key_hash(text) to service_role;
grant execute on function public.airvalet_sms_ticket_eligible(bigint) to service_role;
revoke all on function public.airvalet_sms_reconcile(integer) from public, anon;
grant execute on function public.airvalet_sms_resolve_alert(uuid, text) to authenticated;
grant execute on function public.airvalet_sms_device_request(text, text, text) to authenticated;
grant execute on function public.airvalet_sms_device_status(text) to authenticated;
grant execute on function public.airvalet_sms_device_decide(uuid, text, text) to authenticated;
grant execute on function public.airvalet_sms_set_settings(boolean, boolean, text[], integer, integer, integer, integer, integer, integer) to authenticated;
grant execute on function public.airvalet_sms_set_cutover(text) to authenticated;
grant execute on function public.airvalet_sms_reconcile(integer) to authenticated, service_role;

-- ── Function privileges: service_role only ───────────────────────────────
revoke all on function public.airvalet_sms_normalize_phone(text) from public, anon, authenticated;
revoke all on function public.airvalet_sms_status_rank(text) from public, anon, authenticated;
revoke all on function public.airvalet_sms_claim(text, bigint, text, text, text, text, text, text, integer, text, uuid, integer, integer, text, bytea) from public, anon, authenticated;
revoke all on function public.airvalet_sms_apply_status_row(uuid, text, text, text) from public, anon, authenticated;
revoke all on function public.airvalet_sms_mark_result(uuid, text, text, text, text, text, integer) from public, anon, authenticated;
revoke all on function public.airvalet_sms_apply_status(text, text, text, text, uuid) from public, anon, authenticated;
revoke all on function public.airvalet_sms_match_passenger(text) from public, anon, authenticated;
revoke all on function public.airvalet_sms_record_inbound(text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.airvalet_sms_mark_opted_out(text, text) from public, anon, authenticated;

grant execute on function public.airvalet_sms_normalize_phone(text) to service_role;
grant execute on function public.airvalet_sms_status_rank(text) to service_role;
grant execute on function public.airvalet_sms_claim(text, bigint, text, text, text, text, text, text, integer, text, uuid, integer, integer, text, bytea) to service_role;
grant execute on function public.airvalet_sms_mark_result(uuid, text, text, text, text, text, integer) to service_role;
grant execute on function public.airvalet_sms_apply_status(text, text, text, text, uuid) to service_role;
grant execute on function public.airvalet_sms_match_passenger(text) to service_role;
grant execute on function public.airvalet_sms_record_inbound(text, text, text, text, text) to service_role;
grant execute on function public.airvalet_sms_mark_opted_out(text, text) to service_role;

commit;

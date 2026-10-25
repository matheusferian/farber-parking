-- AirValet Digital Valet Pass — go-live additions (owner GO 2026-10-25).
-- Requires 20261026_airvalet_passenger_portal.sql.
--   1. Valet chat in the passenger page: passenger → valet messages cost no SMS;
--      they land in the same Inbox conversation as texts. Staff replies show
--      in the chat and, by default, also go out as a text (send-sms REPLY);
--      a chat-only reply is stored with provider 'portal'.
--   2. One ticket per check-in: same-day MMDD-N / A-MMDD-N collisions from two
--      devices are re-numbered by the database (per-day lock); a client key
--      makes a retried save return the first row. Old tickets are never touched.
--   3. AIRVALET DIGITAL PASS ON/OFF (ADMIN): one switch for new texts, chat,
--      requests and new check-ins joining. Existing links stay readable.

begin;

-- ── 1. Chat ───────────────────────────────────────────────────────────────
alter table public.airvalet_sms_messages drop constraint airvalet_sms_messages_provider_check;
alter table public.airvalet_sms_messages add constraint airvalet_sms_messages_provider_check
  check (provider in ('twilio', 'mock', 'portal'));
alter table public.airvalet_portal_settings add column if not exists chat_enabled boolean not null default false;

-- Messages of THIS passenger only (never the whole phone number: it may belong
-- to a companion who travels with someone else). Keyword texts are hidden.
create or replace function public.airvalet_portal_messages(p_token text, p_client text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  select * into r from public.airvalet_portal_resolve(p_token, p_client);
  if r.o_state <> 'ok' then return jsonb_build_object('state', r.o_state); end if;
  return jsonb_build_object('state', 'ok', 'messages', coalesce((
    select jsonb_agg(jsonb_build_object(
             'from', case when m.direction = 'inbound' then 'guest' else 'valet' end,
             'body', regexp_replace(coalesce(m.body, ''), 'https://[^\s]*#\*{17}', '(your valet pass link)', 'g'),
             'at', coalesce(m.received_at, m.sent_at, m.created_at),
             'via', case when m.provider = 'portal' then 'chat' else 'text' end) order by m.created_at)
      from (select * from public.airvalet_sms_messages x
             where x.passenger_id = r.o_passenger_id
               and x.message_type not like 'INBOUND\_%'
               and (x.direction = 'inbound' or x.status in ('accepted', 'queued', 'sending', 'sent', 'delivered'))
             order by x.created_at desc limit 60) m), '[]'::jsonb));
end $$;

create or replace function public.airvalet_portal_send_message(p_token text, p_client text, p_body text, p_client_key text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r      record;
  v_p    public.passengers%rowtype;
  -- line breaks kept (the chat shows them); every other control char → space
  v_body text := btrim(regexp_replace(regexp_replace(coalesce(p_body, ''), E'\\r\\n?', E'\\n', 'g'), E'[\\x01-\\x09\\x0b-\\x1f\\x7f]+', ' ', 'g'));
  v_phone text;
  v_id   uuid;
begin
  select * into r from public.airvalet_portal_resolve(p_token, p_client);
  if r.o_state <> 'ok' then return jsonb_build_object('state', r.o_state); end if;
  if not coalesce((select s.chat_enabled from public.airvalet_portal_settings s), false) then
    return jsonb_build_object('state', 'ok', 'result', 'UNAVAILABLE');
  end if;
  if coalesce(p_client_key, '') !~ '^[A-Za-z0-9_-]{16,64}$' or v_body = '' or char_length(v_body) > 600 then
    return jsonb_build_object('state', 'ok', 'result', 'INVALID');
  end if;
  -- Same client key again (double tap / retry): the first message stands.
  select m.id into v_id from public.airvalet_sms_messages m where m.provider_message_sid = 'PORTAL-' || p_client_key;
  if found then return jsonb_build_object('state', 'ok', 'result', 'OK', 'duplicate', true); end if;
  if public.airvalet_pass_hit('m:' || r.o_link_id || ':' || to_char(now(), 'YYYYMMDDHH24')) > 20 then
    return jsonb_build_object('state', 'ok', 'result', 'LIMITED');
  end if;
  select * into v_p from public.passengers p where p.id = r.o_passenger_id;
  v_phone := coalesce(public.airvalet_sms_normalize_phone(v_p.phone), '+10000000000');
  insert into public.airvalet_sms_messages (
    direction, passenger_id, ticket_snapshot, phone_e164, message_type, template_key, body, provider,
    provider_message_sid, status, match_method, received_at)
  values ('inbound', v_p.id, v_p.ticket, v_phone, 'INBOUND', 'PORTAL_CHAT', v_body, 'portal',
          'PORTAL-' || p_client_key, 'received', 'manual', now())
  on conflict (provider_message_sid) do nothing
  returning id into v_id;
  if v_id is null then return jsonb_build_object('state', 'ok', 'result', 'OK', 'duplicate', true); end if;
  return jsonb_build_object('state', 'ok', 'result', 'OK', 'message_id', v_id);
end $$;

-- Staff reply shown in the chat only (no SMS). Only while the passenger has an
-- active valet pass link, otherwise the reply would never be seen.
create or replace function public.airvalet_portal_staff_reply(p_passenger_id bigint, p_body text, p_compose_id text, p_staff_name text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_p public.passengers%rowtype;
  v_body text := btrim(coalesce(p_body, ''));
  v_id uuid;
begin
  perform public.airvalet_portal_require_ops();
  if coalesce(p_compose_id, '') !~ '^[A-Za-z0-9:_-]{8,80}$' or v_body = '' or char_length(v_body) > 600 then
    return jsonb_build_object('result', 'INVALID');
  end if;
  if not exists (select 1 from public.airvalet_pass_links l where l.passenger_id = p_passenger_id and l.revoked_at is null
                   and (l.expires_at is null or l.expires_at > now())) then
    return jsonb_build_object('result', 'NO_PASS_LINK');
  end if;
  select * into v_p from public.passengers p where p.id = p_passenger_id;
  insert into public.airvalet_sms_messages (
    direction, passenger_id, ticket_snapshot, phone_e164, message_type, template_key, body, provider,
    status, idempotency_key, sent_by, sent_by_name, sent_at, delivered_at, segments)
  values ('outbound', v_p.id, v_p.ticket, coalesce(public.airvalet_sms_normalize_phone(v_p.phone), '+10000000000'),
          'REPLY', 'PORTAL_CHAT', v_body, 'portal', 'delivered', 'chat:' || p_compose_id,
          auth.uid(), nullif(left(btrim(coalesce(p_staff_name, '')), 60), ''), now(), now(), 0)
  on conflict (idempotency_key) do nothing
  returning id into v_id;
  return jsonb_build_object('result', 'OK', 'message_id', v_id, 'duplicate', v_id is null);
end $$;

-- ── 2. One ticket per check-in ────────────────────────────────────────────
alter table public.passengers add column if not exists client_key text;
create unique index if not exists passengers_client_key_unique on public.passengers (client_key) where client_key is not null;

create or replace function public.airvalet_ticket_assign()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_day  date := (coalesce(new.checkin_date, now()) at time zone 'America/New_York')::date;
  m      text[];
  v_mmdd text;
  v_max  int;
begin
  if new.ticket is null then return new; end if;
  m := regexp_match(btrim(new.ticket), '^(A-)?(\d{4})-(\d+)$');
  if m is null then return new; end if;                       -- other formats: unchanged (as today)
  v_mmdd := m[2];
  if v_mmdd <> to_char(v_day, 'MMDD') then return new; end if; -- not today's sequence: unchanged
  perform pg_advisory_xact_lock(hashtextextended('airvalet_ticket:' || v_day::text, 0));
  -- Makers and Ascend share ONE daily number sequence (as getSharedDailyMax
  -- does today), so the same N under either prefix counts as taken.
  if exists (select 1 from public.passengers p
              where p.ticket ~ ('^(A-)?' || v_mmdd || '-' || m[3] || '$')
                and (coalesce(p.checkin_date, p.created_at) at time zone 'America/New_York')::date = v_day) then
    select coalesce(max((regexp_match(p.ticket, '^(?:A-)?\d{4}-(\d+)$'))[1]::int), 0) into v_max
      from public.passengers p
     where (coalesce(p.checkin_date, p.created_at) at time zone 'America/New_York')::date = v_day
       and p.ticket ~ ('^(A-)?' || v_mmdd || '-\d+$');
    new.ticket := coalesce(m[1], '') || v_mmdd || '-' || (v_max + 1);
  end if;
  new.ticket := btrim(new.ticket);
  return new;
end $$;
drop trigger if exists airvalet_ticket_assign on public.passengers;
create trigger airvalet_ticket_assign before insert on public.passengers
  for each row execute function public.airvalet_ticket_assign();

-- ── 3. AIRVALET DIGITAL PASS ON / OFF ─────────────────────────────────────
create or replace function public.airvalet_digital_pass_status()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare s public.airvalet_sms_settings%rowtype; p public.airvalet_portal_settings%rowtype;
begin
  perform public.airvalet_portal_require_ops();
  select * into s from public.airvalet_sms_settings x where x.id;
  select * into p from public.airvalet_portal_settings;
  return jsonb_build_object('on', coalesce(s.sending_enabled, false), 'test_only', s.test_only,
    'new_checkins', s.cutover_at is not null, 'portal', p.portal_enabled, 'chat', p.chat_enabled, 'requests', p.requests_enabled);
end $$;

-- OFF: no new texts, chat and requests closed, new check-ins stay on iPhone
-- texting. Tickets, links (read-only), history: all kept. ON: texts, chat,
-- requests and the passenger page on; new check-ins still need the typed
-- START NEW CHECK-INS (gradual activation, unchanged).
create or replace function public.airvalet_digital_pass_set(p_on boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  perform public.airvalet_portal_require_admin();
  if p_on then
    update public.airvalet_sms_settings x set sending_enabled = true, updated_at = now(), updated_by = auth.uid() where x.id;
    update public.airvalet_portal_settings s set portal_enabled = true, chat_enabled = true, requests_enabled = true,
           updated_at = now(), updated_by = auth.uid() where s.id;
  else
    update public.airvalet_sms_settings x set sending_enabled = false, cutover_at = null, cutover_after_id = null,
           updated_at = now(), updated_by = auth.uid() where x.id;
    update public.airvalet_portal_settings s set chat_enabled = false, requests_enabled = false,
           updated_at = now(), updated_by = auth.uid() where s.id;
  end if;
  return public.airvalet_digital_pass_status();
end $$;

-- Portal settings: chat_enabled is editable like the others.
create or replace function public.airvalet_portal_settings_set(p_patch jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k text;
begin
  perform public.airvalet_portal_require_admin();
  for k in select jsonb_object_keys(p_patch) loop
    if k not in ('portal_enabled', 'requests_enabled', 'chat_enabled', 'valet_hours', 'valet_phone', 'text_phone', 'reservations_phone',
                 'car_wash_lead_hours', 'gratuity_url', 'terms_published', 'push_enabled', 'tv_alerts_enabled', 'vapid_public') then
      raise exception 'unknown setting %', k using errcode = '22023';
    end if;
  end loop;
  update public.airvalet_portal_settings s set
    portal_enabled      = coalesce((p_patch ->> 'portal_enabled')::boolean, s.portal_enabled),
    requests_enabled    = coalesce((p_patch ->> 'requests_enabled')::boolean, s.requests_enabled),
    chat_enabled        = coalesce((p_patch ->> 'chat_enabled')::boolean, s.chat_enabled),
    valet_hours         = coalesce(p_patch -> 'valet_hours', s.valet_hours),
    valet_phone         = case when p_patch ? 'valet_phone' then nullif(btrim(p_patch ->> 'valet_phone'), '') else s.valet_phone end,
    text_phone          = case when p_patch ? 'text_phone' then nullif(btrim(p_patch ->> 'text_phone'), '') else s.text_phone end,
    reservations_phone  = case when p_patch ? 'reservations_phone' then nullif(btrim(p_patch ->> 'reservations_phone'), '') else s.reservations_phone end,
    car_wash_lead_hours = coalesce((p_patch ->> 'car_wash_lead_hours')::int, s.car_wash_lead_hours),
    gratuity_url        = case when p_patch ? 'gratuity_url' then nullif(btrim(p_patch ->> 'gratuity_url'), '') else s.gratuity_url end,
    terms_published     = coalesce((p_patch ->> 'terms_published')::boolean, s.terms_published),
    push_enabled        = coalesce((p_patch ->> 'push_enabled')::boolean, s.push_enabled),
    tv_alerts_enabled   = coalesce((p_patch ->> 'tv_alerts_enabled')::boolean, s.tv_alerts_enabled),
    vapid_public        = case when p_patch ? 'vapid_public' then nullif(btrim(p_patch ->> 'vapid_public'), '') else s.vapid_public end,
    updated_at = now(), updated_by = auth.uid()
  where s.id;
  return public.airvalet_portal_settings_get();
end $$;

-- The portal view also tells the page whether the chat is open.
do $$
declare v text := pg_get_functiondef('public.airvalet_portal_view(text,text)'::regprocedure);
begin
  if position('''chat_enabled''' in v) = 0 then
    v := replace(v, '''requests_enabled'', v_set.requests_enabled and v_p.status in (''PENDING'', ''NO DATE''),',
                    '''requests_enabled'', v_set.requests_enabled and v_p.status in (''PENDING'', ''NO DATE''),' || chr(10) ||
                    '      ''chat_enabled'', v_set.chat_enabled and v_p.status <> ''ARCHIVED'',');
    if position('''chat_enabled''' in v) = 0 then raise exception 'portal view patch failed'; end if;
    execute v;
  end if;
end $$;

revoke all on function public.airvalet_portal_messages(text, text) from public, anon, authenticated;
revoke all on function public.airvalet_portal_send_message(text, text, text, text) from public, anon, authenticated;
revoke all on function public.airvalet_portal_staff_reply(bigint, text, text, text) from public, anon;
revoke all on function public.airvalet_ticket_assign() from public, anon, authenticated;
revoke all on function public.airvalet_digital_pass_status() from public, anon;
revoke all on function public.airvalet_digital_pass_set(boolean) from public, anon;
grant execute on function public.airvalet_portal_messages(text, text) to service_role;
grant execute on function public.airvalet_portal_send_message(text, text, text, text) to service_role;
grant execute on function public.airvalet_portal_staff_reply(bigint, text, text, text) to authenticated;
grant execute on function public.airvalet_digital_pass_status() to authenticated;
grant execute on function public.airvalet_digital_pass_set(boolean) to authenticated;

commit;

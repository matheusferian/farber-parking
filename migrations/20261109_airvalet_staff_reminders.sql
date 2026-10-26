-- AirValet — operational reminders as phone push (owner 2026-10-26), working
-- with the app closed. Depends on 20261108 (Vault secrets, staff-alert).
--
-- Every minute pg_cron asks the Edge Function staff-alert (kind REMINDERS) to
-- send what is due. The rules are the ones the staff app already shows
-- (index.html / utils.js), on the real columns, in America/New_York:
--   CW_D3 / CW_D1   car wash requested (carwash_status = 'CARWASH'), return in 3 / 1 days, 09:00
--   CW_DAY          car wash, return today: 08:00 and every 2 h until no longer CARWASH (WASHED / cleared / delivered)
--   CW_E3           car wash pending, return later than in 3 days or not set: every 3 days (from the start day), 09:00
--   FOLLOWUP_E3     cars on the TV Return Follow-Up list: one summary every 3 days (from the start day), 09:00
--   NODATE_ADMIN    active cars without a usable return date: one summary every day, 09:00 (ADMIN phones)
--   GRATUITY        Customs gratuity link due (isCustomsGratuityReminderDue): ETA + 10 min
--   CUSTOMS_WB      Customs delivery, Welcome Back not sent: delivery + 5 min
--   H19_WB          Hangar 19 Welcome Back (WELCOME_BACK_REMINDER_MINUTES): ETA − 30 min
--   MOVE            car not at its pickup place (requiredMove), return today: ETA − move_lead_min.
--                   OFF until the owner sets move_lead_min (no fixed lead time without approval).
--   NO_HANGAR       check-in without a hangar: check-in + 30 min (within 24 h)
--   TMRW_NO_TIME    returns tomorrow without a time: one summary 18:00
--   OVERDUE         return date passed, not delivered: one summary 08:00
-- Each reminder is sent once (airvalet_notify_log key, which carries the return
-- date / time: a changed return re-arms it), only while its condition still
-- holds (done = never sent), and only until it expires. Quiet hours 22:00–06:00:
-- nothing is sent; what is still valid goes out at 06:00 (more than 3 at once for
-- a phone → one summary). Cars of the same flight / same task in one run → one
-- alert listing the tickets. Per-phone categories (NODATE_ADMIN: ADMIN only).
-- Start cutoff (airvalet_staff_reminder_config.since = when this was applied):
-- nothing due before it is ever sent, so the deploy never fires old reminders.
-- Never writes to passengers; a failure never affects the operation.

begin;
set local lock_timeout = '5s';

create extension if not exists pg_cron;   -- already installed in production (1.6.4)

alter table public.airvalet_push_subs add column if not exists reminder_categories text[] not null default '{}';

-- One row. since: reminders due before it are never sent (set when applied; a
-- re-apply keeps it). move_lead_min: minutes before landing for MOVE; null = off.
create table if not exists public.airvalet_staff_reminder_config (
  id boolean primary key default true check (id),
  since timestamptz not null default now(),
  move_lead_min int check (move_lead_min between 15 and 240),
  updated_at timestamptz not null default now()
);
alter table public.airvalet_staff_reminder_config enable row level security;
revoke all on table public.airvalet_staff_reminder_config from public, anon, authenticated;
insert into public.airvalet_staff_reminder_config (id) values (true) on conflict (id) do nothing;

-- ── Parsers: the same rules as the staff app ─────────────────────────────
-- pd(): 'M/D/YYYY' (and 'YYYY-MM-DD'); anything else → null.
create or replace function public.airvalet_ret_date(p text) returns date
language plpgsql immutable set search_path = '' as $$
declare m text[];
begin
  m := regexp_match(btrim(coalesce(p, '')), '^(\d{1,2})/(\d{1,2})/(\d{4})$');
  if m is not null then return make_date(m[3]::int, m[1]::int, m[2]::int); end if;
  m := regexp_match(btrim(coalesce(p, '')), '^(\d{4})-(\d{2})-(\d{2})$');
  if m is not null then return make_date(m[1]::int, m[2]::int, m[3]::int); end if;
  return null;
exception when others then return null;
end $$;

-- isValidDepTime(): strict HH:MM (00:00 allowed) → minutes of day (Welcome Back, MOVE).
create or replace function public.airvalet_wb_eta_min(p text) returns int
language sql immutable set search_path = '' as $$
  select case when p ~ '^\d{2}:\d{2}$' and split_part(p, ':', 1)::int between 0 and 23 and split_part(p, ':', 2)::int between 0 and 59
              then split_part(p, ':', 1)::int * 60 + split_part(p, ':', 2)::int end;
$$;

-- getValidCustomsEtaMinutes(): H:MM / HH:MM or h:mm AM/PM; midnight / placeholders → null.
create or replace function public.airvalet_customs_eta_min(p text) returns int
language plpgsql immutable set search_path = '' as $$
declare v text := upper(btrim(coalesce(p, ''))); m text[]; h int; mi int;
begin
  if v = '' or v in ('HH:MM', '--:--', '00:00', '0:00', '12:00 AM', 'NO ETA', 'NO') then return null; end if;
  m := regexp_match(v, '^([01]?\d|2[0-3]):([0-5]\d)$');
  if m is not null then h := m[1]::int; mi := m[2]::int; return nullif(h * 60 + mi, 0); end if;
  m := regexp_match(v, '^(0?[1-9]|1[0-2]):([0-5]\d)\s*(AM|PM)$');
  if m is not null then
    h := m[1]::int % 12; mi := m[2]::int; if m[3] = 'PM' then h := h + 12; end if;
    return nullif(h * 60 + mi, 0);
  end if;
  return null;
end $$;

-- returnOperator(): column, else not_returning → OTHER, else ticket 'A-…' → ASCEND, else MAKERS.
create or replace function public.airvalet_return_operator_of(p_op text, p_not_returning boolean, p_ticket text) returns text
language sql immutable set search_path = '' as $$
  select case when p_op in ('MAKERS', 'ASCEND', 'OTHER') then p_op when coalesce(p_not_returning, false) then 'OTHER'
              when coalesce(p_ticket, '') like 'A-%' then 'ASCEND' else 'MAKERS' end;
$$;

-- New York wall clock (date + minutes) → instant.
create or replace function public.airvalet_ny_at(p_day date, p_min int) returns timestamptz
language sql immutable set search_path = '' as $$
  select ((p_day::timestamp + make_interval(mins => p_min)) at time zone 'America/New_York');
$$;

-- ── Everything due or upcoming at p_now (pure; read-only) ─────────────────
drop function if exists public.airvalet_staff_reminders(timestamptz);   -- return columns changed in review (re-apply safe)
create or replace function public.airvalet_staff_reminders(p_now timestamptz)
returns table (code text, category text, dedupe_key text, passenger_id bigint, ticket text, body text, due_at timestamptz, expires_at timestamptz,
               grp text, gtext text)
language sql stable security definer set search_path = '' as $$
with t as (select (p_now at time zone 'America/New_York')::date as d),
c as (select (coalesce(max(f.since), p_now) at time zone 'America/New_York')::date as since_d, max(f.move_lead_min) as mv
        from public.airvalet_staff_reminder_config f),
p as (
  select x.id, x.ticket, x.status, x.loc, x.carwash_status, x.departure_time, x.checkin_date, x.obs,
         public.airvalet_ret_date(x.ret) as rd,
         public.airvalet_wb_eta_min(btrim(coalesce(x.departure_time, ''))) as wb_eta,
         public.airvalet_return_operator_of(x.return_operator, x.not_returning_with_makers_air, x.ticket) as op,
         x.delivery_at_customs, x.delivery_type, x.welcome_back_sent_at,
         upper(regexp_replace(btrim(coalesce(x.loc, '')), '\s+', ' ', 'g')) as locn,
         coalesce(x.obs, '') ~* '(APPROX|ESTIMATED RETURN DATE)' as approx
    from public.passengers x where x.status in ('PENDING', 'NO DATE')
),
a as (
  select p.*, case when p.op = 'MAKERS' then case when p.delivery_at_customs then 'CUSTOMS' else 'HANGAR 19' end
                   when p.op = 'ASCEND' then 'CUSTOMS' end as target
    from p
),
cw as (select a.* from a, t where a.carwash_status = 'CARWASH'),
fu as (select a.* from a, t where a.status = 'NO DATE' or a.approx or (a.status = 'PENDING' and (a.rd is null or a.rd < t.d))),
nd as (select a.* from a where a.status = 'NO DATE' or a.rd is null),
del as (  -- Customs deliveries (isCustomsCommEligible): status DELIVERED, type CUSTOMS, after the feature start
  select x.id, x.ticket, x.checkout_date, public.airvalet_ret_date(x.ret) as rd,
         public.airvalet_customs_eta_min(x.departure_time) as c_eta,
         x.customs_welcome_sent, x.customs_gratuity_sent, x.customs_gratuity_dismissed
    from public.passengers x
   where x.status = 'DELIVERED' and x.delivery_type = 'CUSTOMS'
     and x.checkout_date >= timestamptz '2026-07-12 09:50:00-04' and x.checkout_date > p_now - interval '3 days'
)
-- Car wash, 3 / 1 days before
select 'CW_D' || (cw.rd - t.d), 'CARWASH', 'REM:CW_D' || (cw.rd - t.d) || ':' || cw.id || ':' || cw.rd, cw.id, cw.ticket,
       'Car wash in ' || (cw.rd - t.d) || case when cw.rd - t.d = 1 then ' day: ' else ' days: ' end || coalesce(cw.ticket, '?') || ' (' || to_char(cw.rd, 'Dy Mon FMDD') || ')',
       public.airvalet_ny_at(t.d, 540), public.airvalet_ny_at(t.d, 1320),
       'CW_D' || (cw.rd - t.d) || ':' || cw.rd,
       'Car wash in ' || (cw.rd - t.d) || case when cw.rd - t.d = 1 then ' day' else ' days' end || ' (' || to_char(cw.rd, 'Dy Mon FMDD') || '): {t}'
  from cw, t where cw.rd - t.d in (3, 1)
union all
-- Car wash, return day: 08:00, 10:00 … 20:00 until done
select 'CW_DAY', 'CARWASH', 'REM:CW_DAY:' || cw.id || ':' || cw.rd || ':' || s.m, cw.id, cw.ticket,
       'Car wash today: ' || coalesce(cw.ticket, '?') || ' — not marked washed yet',
       public.airvalet_ny_at(t.d, s.m), public.airvalet_ny_at(t.d, s.m + 120),
       'CW_DAY:' || cw.rd || ':' || s.m, 'Car wash today, not marked washed yet: {t}'
  from cw, t, generate_series(480, 1200, 120) s(m) where cw.rd = t.d
union all
-- Car wash pending, return far away or not set: every 3 days
select 'CW_E3', 'CARWASH', 'REM:CW_E3:' || cw.id || ':' || t.d, cw.id, cw.ticket,
       'Car wash pending: ' || coalesce(cw.ticket, '?') || ' (return ' || coalesce(to_char(cw.rd, 'Dy Mon FMDD'), 'not set') || ')',
       public.airvalet_ny_at(t.d, 540), public.airvalet_ny_at(t.d, 1320),
       'CW_E3:' || t.d, 'Car wash pending: {t}'
  from cw, t, c where (cw.rd is null or cw.rd > t.d + 3) and (t.d - c.since_d) % 3 = 0
union all
-- Return follow-up list: one summary every 3 days
select 'FOLLOWUP_E3', 'FOLLOWUP', 'REM:FOLLOWUP_E3:' || t.d, null, null,
       count(*) || case when count(*) = 1 then ' car' else ' cars' end || ' to check (return follow-up): ' || string_agg(coalesce(fu.ticket, '?'), ', ' order by fu.rd nulls first, fu.id),
       public.airvalet_ny_at(t.d, 540), public.airvalet_ny_at(t.d, 1320), null, null
  from fu, t, c where (t.d - c.since_d) % 3 = 0 group by t.d having count(*) > 0
union all
-- No usable return date: one summary every day (ADMIN phones)
select 'NODATE_ADMIN', 'NODATE_ADMIN', 'REM:NODATE_ADMIN:' || t.d, null, null,
       count(*) || case when count(*) = 1 then ' car' else ' cars' end || ' without a return date: ' || string_agg(coalesce(nd.ticket, '?'), ', ' order by nd.id),
       public.airvalet_ny_at(t.d, 540), public.airvalet_ny_at(t.d, 1320), null, null
  from nd, t group by t.d having count(*) > 0
union all
-- Customs gratuity link (after the Customs Welcome Back): ETA + 10 min, that day
select 'GRATUITY', 'CUSTOMS', 'REM:GRATUITY:' || del.id || ':' || del.rd || ':' || del.c_eta, del.id, del.ticket,
       'Send gratuity link: ' || coalesce(del.ticket, '?') || ' (at Customs)',
       public.airvalet_ny_at(del.rd, del.c_eta + 10), public.airvalet_ny_at(del.rd, 1439),
       'GRATUITY:' || del.rd || ':' || del.c_eta, 'Send gratuity link (at Customs): {t}'
  from del where del.customs_welcome_sent is true and del.customs_gratuity_sent is not true and del.customs_gratuity_dismissed is not true
             and del.c_eta is not null and del.rd is not null
union all
-- Customs Welcome Back not sent: delivery + 5 min, for 6 h
select 'CUSTOMS_WB', 'CUSTOMS', 'REM:CUSTOMS_WB:' || del.id || ':' || extract(epoch from del.checkout_date)::bigint, del.id, del.ticket,
       'Send Customs Welcome Back: ' || coalesce(del.ticket, '?'),
       del.checkout_date + interval '5 minutes', del.checkout_date + interval '6 hours',
       'CUSTOMS_WB', 'Send Customs Welcome Back: {t}'
  from del where del.customs_welcome_sent is not true
union all
-- Hangar 19 Welcome Back: ETA − 30 min, until ETA + 2 h
select 'H19_WB', 'WELCOME_BACK', 'REM:H19_WB:' || a.id || ':' || a.rd || ':' || a.wb_eta, a.id, a.ticket,
       'Send Welcome Back: ' || coalesce(a.ticket, '?') || ' lands ' || to_char(make_time(a.wb_eta / 60, a.wb_eta % 60, 0), 'FMHH12:MI AM'),
       public.airvalet_ny_at(a.rd, a.wb_eta - 30), public.airvalet_ny_at(a.rd, a.wb_eta + 120),
       'H19_WB:' || a.rd || ':' || a.wb_eta,
       'Send Welcome Back, lands ' || to_char(make_time(a.wb_eta / 60, a.wb_eta % 60, 0), 'FMHH12:MI AM') || ': {t}'
  from a, t where a.op = 'MAKERS' and coalesce(a.delivery_type, '') <> 'CUSTOMS' and a.welcome_back_sent_at is null
              and a.rd = t.d and a.wb_eta is not null
union all
-- Car not at its pickup place, return today: ETA − move_lead_min (only when set), until ETA + 1 h
select 'MOVE', 'POSITION', 'REM:MOVE:' || a.id || ':' || a.rd || ':' || a.wb_eta || ':' || replace(a.target, ' ', '_') || ':' || c.mv, a.id, a.ticket,
       case when a.target = 'CUSTOMS' then 'Take ' || coalesce(a.ticket, '?') || ' to Customs' else 'Move ' || coalesce(a.ticket, '?') || ' to Hangar 19' end
         || ' — lands ' || to_char(make_time(a.wb_eta / 60, a.wb_eta % 60, 0), 'FMHH12:MI AM'),
       public.airvalet_ny_at(a.rd, a.wb_eta - c.mv), public.airvalet_ny_at(a.rd, a.wb_eta + 60),
       'MOVE:' || a.rd || ':' || a.wb_eta || ':' || replace(a.target, ' ', '_'),
       case when a.target = 'CUSTOMS' then 'Take to Customs' else 'Move to Hangar 19' end
         || ', lands ' || to_char(make_time(a.wb_eta / 60, a.wb_eta % 60, 0), 'FMHH12:MI AM') || ': {t}'
  from a, t, c where c.mv is not null and a.rd = t.d and a.target is not null and a.locn <> a.target and a.wb_eta is not null
union all
-- Check-in without a hangar: + 30 min, within 24 h of the check-in
select 'NO_HANGAR', 'POSITION', 'REM:NO_HANGAR:' || a.id, a.id, a.ticket,
       coalesce(a.ticket, '?') || ' has no hangar — set where the car is',
       a.checkin_date + interval '30 minutes', a.checkin_date + interval '24 hours',
       'NO_HANGAR', 'No hangar set (set where the car is): {t}'
  from a where a.locn = '' and a.checkin_date is not null
union all
-- Returns tomorrow without a time: one summary at 18:00
select 'TMRW_NO_TIME', 'DAILY', 'REM:TMRW_NO_TIME:' || t.d, null, null,
       count(*) || case when count(*) = 1 then ' car leaves' else ' cars leave' end || ' tomorrow without a time: ' || string_agg(coalesce(a.ticket, '?'), ', ' order by a.id),
       public.airvalet_ny_at(t.d, 1080), public.airvalet_ny_at(t.d, 1320), null, null
  from a, t where a.rd = t.d + 1 and a.wb_eta is null group by t.d having count(*) > 0
union all
-- Return date passed, not delivered: one summary at 08:00
select 'OVERDUE', 'DAILY', 'REM:OVERDUE:' || t.d, null, null,
       count(*) || case when count(*) = 1 then ' car is' else ' cars are' end || ' past the return date: ' || string_agg(coalesce(a.ticket, '?'), ', ' order by a.rd, a.id),
       public.airvalet_ny_at(t.d, 480), public.airvalet_ny_at(t.d, 1320), null, null
  from a, t where a.status = 'PENDING' and a.rd < t.d group by t.d having count(*) > 0;
$$;
revoke all on function public.airvalet_staff_reminders(timestamptz) from public, anon, authenticated;
grant execute on function public.airvalet_staff_reminders(timestamptz) to service_role;

-- ── Claim what is due now (once each); nothing in quiet hours ─────────────
create or replace function public.airvalet_staff_reminders_claim(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_local time := (p_now at time zone 'America/New_York')::time; v_out jsonb;
begin
  if v_local >= time '22:00' or v_local < time '06:00' then return '[]'::jsonb; end if;   -- quiet hours
  perform pg_advisory_xact_lock(hashtextextended('airvalet_staff_reminders', 0));
  with due as (
    select r.* from public.airvalet_staff_reminders(p_now) r
     where r.due_at <= p_now and p_now < r.expires_at
       and r.due_at >= coalesce((select f.since from public.airvalet_staff_reminder_config f), p_now)   -- start cutoff
       and not exists (select 1 from public.airvalet_notify_log n where n.dedupe_key = r.dedupe_key)
  ), ins as (
    insert into public.airvalet_notify_log (dedupe_key, channel, status, detail)
    select due.dedupe_key, 'push', 'claimed', due.code from due
    on conflict (dedupe_key) do nothing
    returning dedupe_key
  )
  select coalesce(jsonb_agg(jsonb_build_object('code', due.code, 'category', due.category, 'key', due.dedupe_key,
                                               'ticket', due.ticket, 'body', due.body,
                                               'grp', due.grp, 'gtext', due.gtext) order by due.due_at, due.ticket), '[]'::jsonb)
    into v_out from due join ins on ins.dedupe_key = due.dedupe_key;
  return v_out;
end $$;
revoke all on function public.airvalet_staff_reminders_claim(timestamptz) from public, anon, authenticated;
grant execute on function public.airvalet_staff_reminders_claim(timestamptz) to service_role;

-- ── Phones and their reminder categories ─────────────────────────────────
create or replace function public.airvalet_push_reminder_targets()
returns table (id uuid, endpoint text, p256dh text, auth text, show_preview boolean, categories text[])
language sql stable security definer set search_path = '' as $$
  select s.id, s.endpoint, s.p256dh, s.auth, s.show_preview, s.reminder_categories
    from public.airvalet_push_subs s join public.airvalet_sms_devices d on d.id = s.device_id
   where s.revoked_at is null and s.fail_count < 5 and d.status = 'approved' and cardinality(s.reminder_categories) > 0
     and coalesce((select ps.push_enabled from public.airvalet_portal_settings ps), false);
$$;
revoke all on function public.airvalet_push_reminder_targets() from public, anon, authenticated;
grant execute on function public.airvalet_push_reminder_targets() to service_role;

-- This phone's categories. NODATE_ADMIN: ADMIN login only; the rest: any operations login.
create or replace function public.airvalet_push_reminders_set(p_device_key text, p_categories text[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_dev uuid; v_n int; v_role text := public.current_user_role()::text;
        v_all text[] := array['CARWASH', 'FOLLOWUP', 'CUSTOMS', 'WELCOME_BACK', 'POSITION', 'DAILY', 'NODATE_ADMIN'];
        v_cats text[] := coalesce((select array_agg(distinct c order by c) from unnest(coalesce(p_categories, '{}')) c), '{}');
begin
  if v_role is null or v_role not in ('ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS') then return jsonb_build_object('result', 'FORBIDDEN'); end if;
  if not v_cats <@ v_all then return jsonb_build_object('result', 'BAD_CATEGORY'); end if;
  if 'NODATE_ADMIN' = any (v_cats) and v_role <> 'ADMIN' then return jsonb_build_object('result', 'FORBIDDEN'); end if;
  select d.id into v_dev from public.airvalet_sms_devices d
   where d.key_hash = public.airvalet_sms_device_key_hash(p_device_key) and d.status = 'approved';
  if v_dev is null then return jsonb_build_object('result', 'DEVICE_NOT_AUTHORIZED'); end if;
  update public.airvalet_push_subs s set reminder_categories = v_cats where s.device_id = v_dev and s.revoked_at is null;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('result', 'ALERTS_OFF'); end if;
  return jsonb_build_object('result', 'OK', 'categories', to_jsonb(v_cats));
end $$;
revoke all on function public.airvalet_push_reminders_set(text, text[]) from public, anon;
grant execute on function public.airvalet_push_reminders_set(text, text[]) to authenticated;

create or replace function public.airvalet_push_reminders_get(p_device_key text)
returns text[] language sql stable security definer set search_path = '' as $$
  select coalesce((select array_agg(distinct c order by c) from public.airvalet_push_subs s
                     join public.airvalet_sms_devices d on d.id = s.device_id, unnest(s.reminder_categories) c
                    where d.key_hash = public.airvalet_sms_device_key_hash(p_device_key) and s.revoked_at is null), '{}');
$$;
revoke all on function public.airvalet_push_reminders_get(text) from public, anon;
grant execute on function public.airvalet_push_reminders_get(text) to authenticated;

-- ── Every minute: ask staff-alert to send what is due (Vault: same secrets as 20261108) ──
create or replace function public.airvalet_staff_reminders_tick() returns void
language plpgsql security definer set search_path = '' as $$
declare v_url text; v_jwt text; v_secret text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'airvalet_functions_url';
  select decrypted_secret into v_jwt from vault.decrypted_secrets where name = 'aircraft_tracking_platform_jwt';
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'staff_alert_secret';
  if v_url is null or v_jwt is null or v_secret is null then return; end if;
  perform net.http_post(
    url := rtrim(v_url, '/') || '/staff-alert',
    headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_jwt, 'X-Staff-Alert-Secret', v_secret),
    body := jsonb_build_object('kind', 'REMINDERS'),
    timeout_milliseconds := 20000);
exception when others then
  null;
end $$;
revoke all on function public.airvalet_staff_reminders_tick() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'airvalet-staff-reminders';
select cron.schedule('airvalet-staff-reminders', '* * * * *', 'select public.airvalet_staff_reminders_tick()');

commit;

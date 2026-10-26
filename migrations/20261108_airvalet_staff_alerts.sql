-- AirValet — staff push alerts on the phones (owner 2026-10-26):
--   * CHECK_IN  every new check-in          → ADMIN phones only
--   * TIP       every Stripe tip received   → ADMIN phones only
--   * REMINDER  (next step) operational reminders → iPad / iPhone / ADMIN
-- Opt-in per phone on the existing alerts subscription (airvalet_push_subs),
-- from the Alerts card. A trigger on the new row (any app version, online or
-- offline upload; the Stripe webhook for tips) asks the Edge Function
-- staff-alert to send the push, through pg_net — same pattern as the SSO /
-- aircraft schedulers. The functions URL and the shared secret live in Vault;
-- when they are missing the trigger does nothing. An alert can never block or
-- fail a check-in or a payment. Never sends anything to passengers.
-- Check-in bursts (offline uploads): per minute at most 2 single alerts, then
-- one "more check-ins" alert, then silence. No change to existing functions or data.
--
-- Vault secrets, created out of band (never in this file):
--   airvalet_functions_url          https://<ref>.supabase.co/functions/v1
--   staff_alert_secret              random; same value as the function secret STAFF_ALERT_SECRET
--   aircraft_tracking_platform_jwt  already present (anon JWT for verify_jwt functions)

begin;
set local lock_timeout = '5s';

create extension if not exists pg_net with schema extensions;   -- already installed in production

alter table public.airvalet_push_subs
  add column if not exists notify_checkins  boolean not null default false,
  add column if not exists notify_tips      boolean not null default false,
  add column if not exists notify_reminders boolean not null default false;

-- This phone's choices. CHECK_IN / TIP: ADMIN only. REMINDER: any operations login.
create or replace function public.airvalet_push_alerts_set(p_device_key text, p_kind text, p_on boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_dev uuid; v_n int; v_role public.account_role := public.current_user_role();
begin
  if p_kind not in ('CHECK_IN', 'TIP', 'REMINDER') then return jsonb_build_object('result', 'BAD_KIND'); end if;
  if p_kind in ('CHECK_IN', 'TIP') and v_role is distinct from 'ADMIN'::public.account_role then
    return jsonb_build_object('result', 'FORBIDDEN');
  end if;
  if v_role is null or v_role::text not in ('ADMIN', 'MANAGER', 'IPAD_OPS', 'IPHONE_OPS') then
    return jsonb_build_object('result', 'FORBIDDEN');
  end if;
  select d.id into v_dev from public.airvalet_sms_devices d
   where d.key_hash = public.airvalet_sms_device_key_hash(p_device_key) and d.status = 'approved';
  if v_dev is null then return jsonb_build_object('result', 'DEVICE_NOT_AUTHORIZED'); end if;
  update public.airvalet_push_subs s
     set notify_checkins  = case when p_kind = 'CHECK_IN' then coalesce(p_on, false) else s.notify_checkins end,
         notify_tips      = case when p_kind = 'TIP' then coalesce(p_on, false) else s.notify_tips end,
         notify_reminders = case when p_kind = 'REMINDER' then coalesce(p_on, false) else s.notify_reminders end
   where s.device_id = v_dev and s.revoked_at is null;
  get diagnostics v_n = row_count;
  if v_n = 0 then return jsonb_build_object('result', 'ALERTS_OFF'); end if;
  return jsonb_build_object('result', 'OK', 'kind', p_kind, 'on', coalesce(p_on, false));
end $$;
revoke all on function public.airvalet_push_alerts_set(text, text, boolean) from public, anon;
grant execute on function public.airvalet_push_alerts_set(text, text, boolean) to authenticated;

create or replace function public.airvalet_push_alerts_get(p_device_key text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'check_in', coalesce(bool_or(s.notify_checkins), false),
    'tip',      coalesce(bool_or(s.notify_tips), false),
    'reminder', coalesce(bool_or(s.notify_reminders), false))
    from public.airvalet_push_subs s join public.airvalet_sms_devices d on d.id = s.device_id
   where d.key_hash = public.airvalet_sms_device_key_hash(p_device_key) and s.revoked_at is null;
$$;
revoke all on function public.airvalet_push_alerts_get(text) from public, anon;
grant execute on function public.airvalet_push_alerts_get(text) to authenticated;

-- Service only: phones that asked for this kind of alert (same filter as airvalet_push_targets).
create or replace function public.airvalet_push_staff_targets(p_kind text)
returns table (id uuid, endpoint text, p256dh text, auth text, show_preview boolean)
language sql stable security definer set search_path = '' as $$
  select s.id, s.endpoint, s.p256dh, s.auth, s.show_preview
    from public.airvalet_push_subs s join public.airvalet_sms_devices d on d.id = s.device_id
   where s.revoked_at is null and s.fail_count < 5 and d.status = 'approved'
     and coalesce((select ps.push_enabled from public.airvalet_portal_settings ps), false)
     and case p_kind when 'CHECK_IN' then s.notify_checkins when 'TIP' then s.notify_tips
                     when 'REMINDER' then s.notify_reminders else false end;
$$;
revoke all on function public.airvalet_push_staff_targets(text) from public, anon, authenticated;
grant execute on function public.airvalet_push_staff_targets(text) to service_role;

-- Service only: one claim per event; returns what the alert says.
--   CHECK_IN: per minute 2 single alerts, then one "more check-ins", then silence.
--   TIP: one alert per succeeded Stripe tip.
create or replace function public.airvalet_staff_alert_claim(p_kind text, p_id bigint)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_key text := 'push:' || p_kind || ':' || p_id; v_recent int; v_mode text; v_p record; v_t record;
begin
  if p_kind = 'CHECK_IN' then
    perform pg_advisory_xact_lock(hashtextextended('airvalet_staff_alert_checkin', 0));
    select p.id, p.name, p.ticket, p.loc, p.status into v_p from public.passengers p where p.id = p_id;
    if not found or v_p.status not in ('PENDING', 'NO DATE') then return jsonb_build_object('mode', 'skip'); end if;
    if exists (select 1 from public.airvalet_notify_log n where n.dedupe_key = v_key) then return jsonb_build_object('mode', 'skip'); end if;
    select count(*) into v_recent from public.airvalet_notify_log n
     where n.channel = 'push' and n.dedupe_key like 'push:CHECK\_IN:%' and n.created_at > now() - interval '60 seconds';
    v_mode := case when v_recent < 2 then 'single' when v_recent = 2 then 'summary' else 'skip' end;
    insert into public.airvalet_notify_log (dedupe_key, channel, status, detail)
    values (v_key, 'push', case when v_mode = 'skip' then 'skipped' else 'claimed' end, v_mode);
    return jsonb_build_object('mode', v_mode, 'key', v_key, 'name', v_p.name, 'ticket', v_p.ticket, 'loc', v_p.loc);
  elsif p_kind = 'TIP' then
    select t.id, t.amount_cents, coalesce(nullif(t.ticket, ''), p.ticket) as ticket, p.name
      into v_t from public.payments t left join public.passengers p on p.id = t.passenger_id
     where t.id = p_id and t.type = 'TIP' and t.method = 'STRIPE' and t.status = 'succeeded';
    if not found then return jsonb_build_object('mode', 'skip'); end if;
    insert into public.airvalet_notify_log (dedupe_key, channel) values (v_key, 'push') on conflict (dedupe_key) do nothing;
    if not found then return jsonb_build_object('mode', 'skip'); end if;
    return jsonb_build_object('mode', 'single', 'key', v_key, 'amount_cents', v_t.amount_cents, 'ticket', v_t.ticket, 'name', v_t.name);
  end if;
  return jsonb_build_object('mode', 'skip');
end $$;
revoke all on function public.airvalet_staff_alert_claim(text, bigint) from public, anon, authenticated;
grant execute on function public.airvalet_staff_alert_claim(text, bigint) to service_role;

-- The triggers: queue one HTTP call per new row (TG_ARGV[0] = kind). Never blocks or fails it.
create or replace function public.airvalet_staff_alert_hook()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_url text; v_jwt text; v_secret text;
begin
  begin
    select decrypted_secret into v_url from vault.decrypted_secrets where name = 'airvalet_functions_url';
    select decrypted_secret into v_jwt from vault.decrypted_secrets where name = 'aircraft_tracking_platform_jwt';
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'staff_alert_secret';
    if v_url is null or v_jwt is null or v_secret is null then return null; end if;
    perform net.http_post(
      url := rtrim(v_url, '/') || '/staff-alert',
      headers := jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_jwt,
                                    'X-Staff-Alert-Secret', v_secret),
      body := jsonb_build_object('kind', tg_argv[0], 'id', new.id),
      timeout_milliseconds := 10000);
  exception when others then
    null;   -- an alert must never block a check-in or a payment
  end;
  return null;
end $$;
revoke all on function public.airvalet_staff_alert_hook() from public, anon, authenticated;

drop trigger if exists airvalet_staff_alert_checkin on public.passengers;
create trigger airvalet_staff_alert_checkin after insert on public.passengers
  for each row when (new.status in ('PENDING', 'NO DATE'))
  execute function public.airvalet_staff_alert_hook('CHECK_IN');

drop trigger if exists airvalet_staff_alert_tip on public.payments;
create trigger airvalet_staff_alert_tip after insert on public.payments
  for each row when (new.type = 'TIP' and new.method = 'STRIPE' and new.status = 'succeeded')
  execute function public.airvalet_staff_alert_hook('TIP');

commit;

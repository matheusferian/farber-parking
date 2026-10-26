-- AirValet — portal abuse limits (post-deploy audit 2026-10-25, NOT applied
-- in production; needs owner authorization). Three small fixes, no data change:
--
-- 1. Per-link limits really are per day / per hour. airvalet_pass_hit() always
--    counted in 10-minute windows (and the rows are deleted after 1 hour), so
--    "12 requests per day" (bucket r:<link>:<day>) and "20 chat messages per
--    hour" (bucket m:<link>:<hour>) reset every 10 minutes. Those buckets now
--    count for their whole life in their own table (the name carries the day /
--    hour). Every other bucket keeps the 10-minute window.
-- 2. Texts from unknown numbers can no longer use up the Super Admin alert cap:
--    one alert per window for all unknown senders together, at most 5 a day.
-- 3. Push subscriptions only to the real push services (Apple, Google,
--    Mozilla, Microsoft), never to an arbitrary https server.
-- 4. Stripe tip totals only for the operation roles (the TV login could read
--    the revenue of any day).
--
-- Rollback: 20261107_airvalet_portal_abuse_limits_rollback.sql

-- ── 1. Long-window rate buckets ───────────────────────────────────────────
-- One transaction (audit v77): all of it or nothing. lock_timeout: fail fast, change nothing.
begin;
set local lock_timeout = '5s';

create table if not exists public.airvalet_pass_rate_long (
  bucket     text primary key,
  hits       integer not null default 0,
  first_hit  timestamptz not null default now()
);
alter table public.airvalet_pass_rate_long enable row level security;
revoke all on table public.airvalet_pass_rate_long from public, anon, authenticated;

create or replace function public.airvalet_pass_hit(p_bucket text)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare v integer;
begin
  -- r:<link>:<day> and m:<link>:<hour>: the name already carries its period.
  if p_bucket like 'r:%' or p_bucket like 'm:%' then
    if random() < 0.02 then
      delete from public.airvalet_pass_rate_long l where l.first_hit < now() - interval '26 hours';
    end if;
    insert into public.airvalet_pass_rate_long (bucket, hits) values (p_bucket, 1)
    on conflict (bucket) do update set hits = public.airvalet_pass_rate_long.hits + 1
    returning hits into v;
    return v;
  end if;
  insert into public.airvalet_pass_rate (bucket, window_start, hits)
  values (p_bucket, date_bin('10 minutes', now(), timestamptz '2000-01-01'), 1)
  on conflict (bucket, window_start) do update set hits = public.airvalet_pass_rate.hits + 1
  returning hits into v;
  return v;
end;
$$;
revoke all on function public.airvalet_pass_hit(text) from public, anon, authenticated;

-- ── 2. Super Admin alerts: unknown senders ────────────────────────────────
create or replace function public.airvalet_admin_alert_claim(p_event text, p_passenger_id bigint, p_phone_e164 text, p_dedupe_key text)
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
  -- Unknown number (no passenger, key admin:<kind>:px:<ref>): one alert per
  -- window for all of them together and at most 5 a day, so texts from a
  -- stranger can never use up the daily cap meant for real guests.
  if p_passenger_id is null and (
       exists (select 1 from public.airvalet_notify_log n
                where n.channel = 'admin_sms' and n.status in ('claimed', 'sent')
                  and n.dedupe_key like 'admin:%:px:%'
                  and n.created_at > now() - make_interval(mins => a.per_guest_window_min))
       or (select count(*) from public.airvalet_notify_log n
            where n.channel = 'admin_sms' and n.status in ('claimed', 'sent')
              and n.dedupe_key like 'admin:%:px:%'
              and n.created_at > now() - interval '24 hours') >= 5) then return null; end if;
  insert into public.airvalet_notify_log (dedupe_key, channel) values (p_dedupe_key, 'admin_sms')
  on conflict (dedupe_key) do nothing;
  if not found then return null; end if;
  return a.phone_e164;
end $$;
revoke all on function public.airvalet_admin_alert_claim(text, bigint, text, text) from public, anon, authenticated;
grant execute on function public.airvalet_admin_alert_claim(text, bigint, text, text) to service_role;

-- ── 3. Push subscriptions: real push services only ────────────────────────
create or replace function public.airvalet_push_subscribe(p_device_key text, p_endpoint text, p_p256dh text, p_auth text, p_show_preview boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_dev uuid;
begin
  perform public.airvalet_portal_require_ops();
  if coalesce(p_endpoint, '') !~ '^https://(web\.push\.apple\.com|[a-z0-9-]+(\.[a-z0-9-]+)*\.push\.apple\.com|fcm\.googleapis\.com|android\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9-]+(\.[a-z0-9-]+)*\.notify\.windows\.com)/' then
    return jsonb_build_object('result', 'ENDPOINT_NOT_ALLOWED');
  end if;
  select d.id into v_dev from public.airvalet_sms_devices d
   where d.key_hash = public.airvalet_sms_device_key_hash(p_device_key) and d.status = 'approved';
  if v_dev is null then return jsonb_build_object('result', 'DEVICE_NOT_AUTHORIZED'); end if;
  insert into public.airvalet_push_subs (device_id, endpoint, p256dh, auth, show_preview)
  values (v_dev, p_endpoint, p_p256dh, p_auth, coalesce(p_show_preview, false))
  on conflict (endpoint) do update set device_id = excluded.device_id, p256dh = excluded.p256dh, auth = excluded.auth,
         show_preview = excluded.show_preview, revoked_at = null, fail_count = 0;
  return jsonb_build_object('result', 'OK');
end $$;
revoke all on function public.airvalet_push_subscribe(text, text, text, text, boolean) from public, anon;
grant execute on function public.airvalet_push_subscribe(text, text, text, text, boolean) to authenticated;

-- ── 4. Stripe tip totals: operation roles only ────────────────────────────
create or replace function public.get_stripe_tips_for_date_cents(target_date date)
returns bigint language plpgsql stable security definer set search_path = public as $$
begin
  if public.current_user_role() is null
     or public.current_user_role() not in ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'MANAGER') then
    raise exception 'get_stripe_tips_for_date_cents: role not permitted' using errcode = '42501';
  end if;
  return (select coalesce(sum(amount_cents), 0)::bigint
            from public.payments
           where type = 'TIP' and method = 'STRIPE' and status = 'succeeded'
             and (created_at at time zone 'America/New_York')::date = target_date);
end $$;
create or replace function public.get_stripe_tips_today_cents()
returns bigint language plpgsql stable security definer set search_path = public as $$
begin
  return public.get_stripe_tips_for_date_cents((now() at time zone 'America/New_York')::date);
end $$;
revoke execute on function public.get_stripe_tips_for_date_cents(date) from public, anon;
revoke execute on function public.get_stripe_tips_today_cents() from public, anon;
grant execute on function public.get_stripe_tips_for_date_cents(date) to authenticated;
grant execute on function public.get_stripe_tips_today_cents() to authenticated;

commit;

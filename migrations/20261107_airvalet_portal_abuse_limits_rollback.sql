-- Rollback of 20261107_airvalet_portal_abuse_limits.sql: the definitions in
-- production before it (20261010 / 20261026 / 20260930), byte-for-byte bodies.

drop table if exists public.airvalet_pass_rate_long;

create or replace function public.airvalet_pass_hit(p_bucket text)
returns integer
language sql
security definer
set search_path = ''
as $$
  insert into public.airvalet_pass_rate (bucket, window_start, hits)
  values (p_bucket, date_bin('10 minutes', now(), timestamptz '2000-01-01'), 1)
  on conflict (bucket, window_start) do update set hits = public.airvalet_pass_rate.hits + 1
  returning hits;
$$;
revoke all on function public.airvalet_pass_hit(text) from public, anon, authenticated;

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
  insert into public.airvalet_notify_log (dedupe_key, channel) values (p_dedupe_key, 'admin_sms')
  on conflict (dedupe_key) do nothing;
  if not found then return null; end if;
  return a.phone_e164;
end $$;
revoke all on function public.airvalet_admin_alert_claim(text, bigint, text, text) from public, anon, authenticated;
grant execute on function public.airvalet_admin_alert_claim(text, bigint, text, text) to service_role;

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
revoke all on function public.airvalet_push_subscribe(text, text, text, text, boolean) from public, anon;
grant execute on function public.airvalet_push_subscribe(text, text, text, text, boolean) to authenticated;

drop function if exists public.get_stripe_tips_today_cents();
drop function if exists public.get_stripe_tips_for_date_cents(date);
create function public.get_stripe_tips_for_date_cents(target_date date)
 returns bigint
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce(sum(amount_cents), 0)::bigint
  from public.payments
  where type = 'TIP' and method = 'STRIPE' and status = 'succeeded'
    and (created_at at time zone 'America/New_York')::date = target_date;
$function$;
create function public.get_stripe_tips_today_cents()
 returns bigint
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce(sum(amount_cents), 0)::bigint
  from public.payments
  where type = 'TIP' and method = 'STRIPE' and status = 'succeeded'
    and (created_at at time zone 'America/New_York')::date
      = (now() at time zone 'America/New_York')::date;
$function$;
revoke execute on function public.get_stripe_tips_for_date_cents(date) from public, anon;
revoke execute on function public.get_stripe_tips_today_cents() from public, anon;
grant execute on function public.get_stripe_tips_for_date_cents(date) to authenticated;
grant execute on function public.get_stripe_tips_today_cents() to authenticated;

-- Makers robot (2026-11-06, owner): every day at 3 PM Fort Lauderdale the makers-sync Edge Function
-- reads tomorrow's Makers Air Suite flights (READ-ONLY), and at 7 AM it re-checks the same day; the
-- result is saved in airvalet_manifest_scans
-- (usage.mode = 'makers_sync'). The app shows the latest result through airvalet_manifest_latest().
--
-- pg_cron is UTC: the job fires at 11, 12, 19 and 20 UTC and the function itself only works in the runs
-- that are 07:00 or 15:00 in America/New_York (EDT or EST), so daylight saving needs no change here.
-- Headers come from Vault at run time by NAME: aircraft_tracking_platform_jwt (the anon key, already
-- used by the aircraft job) and makers_sync_secret (created out of band, same value as the function's
-- MAKERS_SYNC_SECRET). The migration refuses to schedule the job if either is missing.
begin;
set local lock_timeout = '5s';

create or replace function public.airvalet_manifest_latest()
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare v jsonb;
begin
  perform public.airvalet_portal_require_ops();
  select jsonb_build_object('created_at', s.created_at, 'service_date', s.service_date,
           'ok', coalesce((s.usage->>'ok')::boolean, false), 'result', s.result)
    into v
    from public.airvalet_manifest_scans s
   where s.usage->>'mode' = 'makers_sync'
     and s.service_date >= (now() at time zone 'America/New_York')::date
   order by s.created_at desc limit 1;
  return v;
end $function$;
revoke all on function public.airvalet_manifest_latest() from public, anon;
grant execute on function public.airvalet_manifest_latest() to authenticated;

do $$
declare v_missing text;
begin
  select string_agg(n, ', ') into v_missing from (values ('aircraft_tracking_platform_jwt'), ('makers_sync_secret')) as x(n)
   where not exists (select 1 from vault.secrets s where s.name = x.n);
  if v_missing is not null then
    raise exception 'makers-sync: Vault secret(s) missing: %', v_missing;
  end if;
end $$;

select cron.schedule(
  'makers-sync',
  '0 11,12,19,20 * * *',
  $$
  select net.http_post(
    url := 'https://sfewtirvqhrpanwhbchd.supabase.co/functions/v1/makers-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'aircraft_tracking_platform_jwt'),
      'X-Makers-Sync-Secret', (select decrypted_secret from vault.decrypted_secrets where name = 'makers_sync_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 120000
  );
  $$
);

commit;

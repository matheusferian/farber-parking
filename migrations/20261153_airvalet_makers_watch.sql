-- Makers robot quick check (owner 2026-11-12: DAVID HOCHER moved from the 11:00 to a 5 PM flight after the
-- 6 AM reading and nobody knew). Every 30 minutes makers-sync {"watch":true} reads TODAY's arrivals at FXE
-- (2 read-only searches) and pushes "Flight changed" when a guest with a car here moved, left every flight
-- or appeared on one. The function only works from 6:30 AM to 6 PM Fort Lauderdale (EDT or EST) and skips
-- the slots of the other robot runs (6 AM, 11 AM, 3 PM, 4:30 PM, Monday 8 AM).
begin;
set local lock_timeout = '5s';
select cron.schedule('makers-watch', '*/30 * * * *', $cmd$
  select net.http_post(
    url := 'https://sfewtirvqhrpanwhbchd.supabase.co/functions/v1/makers-sync',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name = 'aircraft_tracking_platform_jwt'),
      'X-Makers-Sync-Secret', (select decrypted_secret from vault.decrypted_secrets where name = 'makers_sync_secret')
    ),
    body := '{"watch":true}'::jsonb,
    timeout_milliseconds := 60000
  );
$cmd$);
commit;

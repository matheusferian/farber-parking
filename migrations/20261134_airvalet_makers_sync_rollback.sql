-- Rollback of 20261134_airvalet_makers_sync.sql: stop the robot job and remove the read function.
-- The Vault secret makers_sync_secret and the scan rows are left (harmless; delete by hand if wanted).
begin;
select cron.unschedule('makers-sync') where exists (select 1 from cron.job where jobname = 'makers-sync');
drop function if exists public.airvalet_manifest_latest();
commit;

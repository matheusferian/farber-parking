-- Rollback of 20261145: no 4:30 PM run.
begin;
select cron.unschedule('makers-sync-1630') where exists (select 1 from cron.job where jobname = 'makers-sync-1630');
commit;

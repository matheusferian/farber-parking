-- Rollback of 20261136: back to the 7 AM / 3 PM firing hours (11,12,19,20 UTC). Redeploy the previous
-- makers-sync function too (h === 7), or the morning run is skipped.
begin;
set local lock_timeout = '5s';
select cron.alter_job((select jobid from cron.job where jobname = 'makers-sync'), schedule := '0 11,12,19,20 * * *');
commit;

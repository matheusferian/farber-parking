-- Rollback of 20261143: back to 6 AM / 3 PM only (redeploy the previous makers-sync too).
begin;
set local lock_timeout = '5s';
select cron.alter_job((select jobid from cron.job where jobname = 'makers-sync'), schedule := '0 10,11,19,20 * * *');
commit;

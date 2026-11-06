-- Rollback of 20261144: back to 6 AM, 11 AM, 3 PM, 7 PM.
begin;
set local lock_timeout = '5s';
select cron.alter_job((select jobid from cron.job where jobname = 'makers-sync'), schedule := '0 0,10,11,15,16,19,20,23 * * *');
commit;

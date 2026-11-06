-- Makers robot (owner 2026-11-06, "just in case"): one more run at 11 PM Fort Lauderdale (reads TOMORROW,
-- pushes only on changes). 11 PM ET = 03 UTC (EDT) / 04 UTC (EST).
begin;
set local lock_timeout = '5s';
select cron.alter_job((select jobid from cron.job where jobname = 'makers-sync'), schedule := '0 0,3,4,10,11,15,16,19,20,23 * * *');
commit;

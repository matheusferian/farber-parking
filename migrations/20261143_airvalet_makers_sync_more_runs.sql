-- Makers robot (owner 2026-11-06): four runs a day, Fort Lauderdale time — 6 AM and 11 AM read TODAY,
-- 3 PM and 7 PM read TOMORROW. pg_cron is UTC: 6 AM = 10/11, 11 AM = 15/16, 3 PM = 19/20, 7 PM = 23/0
-- (EDT/EST); makers-sync works only in the run that matches the local hour. 11 AM / 7 PM push only on changes.
begin;
set local lock_timeout = '5s';
select cron.alter_job((select jobid from cron.job where jobname = 'makers-sync'), schedule := '0 0,10,11,15,16,19,20,23 * * *');
commit;

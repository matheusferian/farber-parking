-- Rollback of 20261111_airvalet_cron_log_retention.sql: the schedule first (no
-- more purges), then the function and the daily summary table. Log rows that
-- were already purged cannot come back; their per-day counts are in
-- airvalet_cron_run_daily, so export that table first if it should be kept.

begin;
set local lock_timeout = '5s';

select cron.unschedule(jobid) from cron.job where jobname = 'airvalet-cron-log-retention';
drop function if exists public.airvalet_cron_log_purge(interval, interval, integer);
drop table if exists public.airvalet_cron_run_daily;

commit;

begin;
select cron.unschedule(jobid) from cron.job where jobname = 'airvalet-makers-scans-purge';
-- names RPC / purge: re-run migrations/20261148_airvalet_makers_names_after_departure.sql to restore the previous regex.
drop function if exists public.airvalet_robot_unlock(text);
drop function if exists public.airvalet_robot_lock(text, integer);
drop table if exists public.airvalet_robot_locks;
commit;

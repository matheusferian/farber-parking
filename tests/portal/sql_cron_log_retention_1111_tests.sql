-- LOCAL DB tests for 20261111_airvalet_cron_log_retention.sql. One transaction, rolled back. Runner:
--   (echo '\set ON_ERROR_STOP 1'; echo 'begin;'; sed '/^begin;$/d;/^commit;$/d' migrations/20261111_airvalet_cron_log_retention.sql;
--    cat tests/portal/sql_cron_log_retention_1111_tests.sql; echo 'rollback;') | docker exec -i supabase_db_airvalet-portal-local psql -U postgres -d postgres

create function pg_temp.check(cond boolean, label text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', label; end if;
  raise notice 'ok  %', label;
end $$;

select pg_temp.check(exists (select 1 from cron.job where jobname = 'airvalet-cron-log-retention' and schedule = '17 * * * *'
  and command = 'select public.airvalet_cron_log_purge()'), 'scheduled every hour at :17');
select pg_temp.check(not has_function_privilege('anon', 'public.airvalet_cron_log_purge(interval,interval,integer)', 'execute')
  and not has_function_privilege('authenticated', 'public.airvalet_cron_log_purge(interval,interval,integer)', 'execute'), 'purge: not callable by the app');
select pg_temp.check(not has_table_privilege('authenticated', 'public.airvalet_cron_run_daily', 'select')
  and not has_table_privilege('anon', 'public.airvalet_cron_run_daily', 'select'), 'daily summary: not readable by the app');

select count(*) as notify_before from public.airvalet_notify_log \gset
-- Synthetic log rows for two test jobs (everything else in the local log is left out of the counts).
select cron.schedule('zz-test-ok', '0 0 1 1 *', 'select 1') as j_ok \gset
select cron.schedule('zz-test-other', '0 0 1 1 *', 'select 1') as j_other \gset
delete from cron.job_run_details where jobid in (:j_ok, :j_other);
insert into cron.job_run_details (jobid, runid, job_pid, database, username, command, status, return_message, start_time, end_time)
select :j_ok, 9100000 + g, 1, 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', now() - make_interval(days => 10) + make_interval(mins => g), now() - make_interval(days => 10) + make_interval(mins => g, secs => 1)
  from generate_series(1, 5) g;                                                 -- 5 old successes → purged
insert into cron.job_run_details (jobid, runid, job_pid, database, username, command, status, return_message, start_time, end_time)
select :j_ok, 9100100 + g, 1, 'postgres', 'postgres', 'select 1', 'succeeded', '1 row', now() - interval '2 days', now() - interval '2 days'
  from generate_series(1, 3) g;                                                 -- 3 recent successes → kept
insert into cron.job_run_details (jobid, runid, job_pid, database, username, command, status, return_message, start_time, end_time) values
  (:j_other, 9100201, 1, 'postgres', 'postgres', 'select 1', 'failed', 'ERROR: boom', now() - interval '10 days', now() - interval '10 days'),   -- failure 10 days → kept
  (:j_other, 9100202, 1, 'postgres', 'postgres', 'select 1', 'failed', 'ERROR: old', now() - interval '200 days', now() - interval '200 days'), -- failure 200 days → purged
  (:j_other, 9100203, 1, 'postgres', 'postgres', 'select 1', 'running', null, now() - interval '200 days', null);                              -- stuck run, 200 days → purged
create function pg_temp.left_rows() returns text language sql as $$
  select string_agg(runid::text, ',' order by runid) from cron.job_run_details where runid between 9100000 and 9100999 $$;

select pg_temp.check((public.airvalet_cron_log_purge(interval '7 days', interval '180 days', 3)->>'deleted')::int >= 1, 'purge removes one batch at a time');
select public.airvalet_cron_log_purge() ;   -- the rest of the backlog
select public.airvalet_cron_log_purge() ;
select pg_temp.check(pg_temp.left_rows() = '9100101,9100102,9100103,9100201', 'kept: successes of the last 7 days and the 10-day-old failure; purged: old successes, 200-day failure, stuck run');
select pg_temp.check((select runs from public.airvalet_cron_run_daily where jobname = 'zz-test-ok' and status = 'succeeded') = 5
  and (select sum(runs) from public.airvalet_cron_run_daily where jobname = 'zz-test-other') = 2
  and (select runs from public.airvalet_cron_run_daily where jobname = 'zz-test-other' and status = 'failed') = 1
  and (select max_ms from public.airvalet_cron_run_daily where jobname = 'zz-test-ok' and status = 'succeeded') = 1000,
  'every purged run is counted in the permanent daily summary (job, day, status, max duration)');
select pg_temp.check((public.airvalet_cron_log_purge()->>'deleted')::int = 0 or pg_temp.left_rows() = '9100101,9100102,9100103,9100201', 'running it again changes nothing for the kept rows');
select pg_temp.check((select sum(runs) from public.airvalet_cron_run_daily where jobname like 'zz-test-%') = 7, 'no double counting in the summary');
select pg_temp.check((select count(*) from public.airvalet_notify_log) = :notify_before, 'notification audit (airvalet_notify_log) is not touched');
do $$ begin
  perform public.airvalet_cron_log_purge(interval '1 hour', interval '180 days', 100);
  raise exception 'FAIL: unsafe retention accepted';
exception when others then
  if sqlerrm like 'FAIL:%' then raise; end if;
  raise notice 'ok  refuses to keep less than 1 day of successes / 30 days of failures';
end $$;

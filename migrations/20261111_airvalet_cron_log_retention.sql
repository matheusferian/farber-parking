-- AirValet — retention for the pg_cron run log (owner 2026-10-26).
--
-- cron.job_run_details had no cleanup since 2026-08-29: ~112k rows / 111 MB
-- from the per-minute jobs (refresh-aircraft-state, sso-revalidate; 1109 adds
-- one more). Every hour at :17 one batch is removed:
--   succeeded runs   older than 7 days
--   any other status older than 180 days (failures stay for audit)
-- Before a row goes, it is counted in airvalet_cron_run_daily (per New York
-- day, job and status: runs, max duration), kept permanently, so the history
-- of what ran and what failed survives. airvalet_notify_log is not touched.
-- Batches of 20,000: the current backlog (~92k) is gone in about 5 hours,
-- then each run removes ~3 hours' worth. Reversible: see _rollback.sql.

begin;
set local lock_timeout = '5s';

create extension if not exists pg_cron;   -- already installed in production (1.6.4)

create table if not exists public.airvalet_cron_run_daily (
  day date not null,
  jobname text not null,
  status text not null,
  runs integer not null default 0,
  max_ms integer,
  updated_at timestamptz not null default now(),
  primary key (day, jobname, status)
);
alter table public.airvalet_cron_run_daily enable row level security;
revoke all on table public.airvalet_cron_run_daily from public, anon, authenticated;

create or replace function public.airvalet_cron_log_purge(p_keep_ok interval default '7 days', p_keep_other interval default '180 days',
                                                          p_batch integer default 20000)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_n integer := 0;
begin
  if p_keep_ok < interval '1 day' or p_keep_other < interval '30 days' or p_batch not between 1 and 100000 then
    raise exception 'airvalet_cron_log_purge: keep at least 1 day of successes / 30 days of failures, batch 1..100000';
  end if;
  -- One statement: count the batch into the daily summary, then remove it.
  with v as (
    select d.runid, d.jobid, d.status, d.start_time, d.end_time
      from cron.job_run_details d
     where coalesce(d.end_time, d.start_time) < now() - case when d.status = 'succeeded' then p_keep_ok else p_keep_other end
     order by d.runid
     limit p_batch
  ), summary as (
    insert into public.airvalet_cron_run_daily (day, jobname, status, runs, max_ms)
    select (coalesce(v.start_time, v.end_time) at time zone 'America/New_York')::date,
           coalesce(j.jobname, 'job ' || v.jobid), coalesce(v.status, '?'), count(*),
           max((extract(epoch from (v.end_time - v.start_time)) * 1000)::integer)
      from v left join cron.job j on j.jobid = v.jobid
     group by 1, 2, 3
    on conflict (day, jobname, status) do update
       set runs = public.airvalet_cron_run_daily.runs + excluded.runs,
           max_ms = greatest(public.airvalet_cron_run_daily.max_ms, excluded.max_ms),
           updated_at = now()
    returning 1
  ), gone as (
    delete from cron.job_run_details d using v where d.runid = v.runid returning 1
  )
  select count(*) into v_n from gone;
  return jsonb_build_object('deleted', v_n);
end $$;
revoke all on function public.airvalet_cron_log_purge(interval, interval, integer) from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'airvalet-cron-log-retention';
select cron.schedule('airvalet-cron-log-retention', '17 * * * *', 'select public.airvalet_cron_log_purge()');

commit;

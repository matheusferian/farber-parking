-- Makers robot morning run moves from 7 AM to 6 AM Fort Lauderdale (owner 2026-11-06: the Makers office
-- is open by 6 AM, so the morning check catches their last changes). 3 PM (tomorrow) is unchanged.
-- pg_cron is UTC: 6 AM ET = 10 UTC (EDT) / 11 UTC (EST); 3 PM ET = 19 / 20 UTC. The makers-sync function
-- only works in the run that is 6 AM or 3 PM in America/New_York, so daylight saving needs no change.
-- cron.schedule with an existing job name replaces that job's schedule and command.
begin;
set local lock_timeout = '5s';
do $$
begin
  if not exists (select 1 from cron.job where jobname = 'makers-sync') then
    raise exception 'makers-sync job not found (apply 20261134 first)';
  end if;
end $$;
select cron.alter_job((select jobid from cron.job where jobname = 'makers-sync'), schedule := '0 10,11,19,20 * * *');
commit;

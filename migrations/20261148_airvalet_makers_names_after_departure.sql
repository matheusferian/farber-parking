-- Owner 2026-11-06: a flight's names go away once it has left (30 min after the scheduled FXE departure,
-- room for a small delay), not only at the end of the day. Tomorrow's names stay until their day.
begin;
set local lock_timeout = '5s';

create or replace function public.airvalet_makers_names_get()
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare v_now timestamp := now() at time zone 'America/New_York'; v_today date := v_now::date;
begin
  perform public.airvalet_portal_require_ops();
  return coalesce((select jsonb_agg(jsonb_build_object('d', case when n.service_date = v_today then 0 else 1 end,
            'name', n.name, 'flight', n.flight, 'time', n.dep_time, 'dest', n.dest) order by n.service_date, n.dep_time, n.name)
     from public.airvalet_makers_names n
    where n.service_date = v_today + 1
       or (n.service_date = v_today and (n.dep_time !~ '^\d{1,2}:\d{2}' or v_today + n.dep_time::time + interval '30 minutes' >= v_now))), '[]'::jsonb);
end $function$;
revoke all on function public.airvalet_makers_names_get() from public, anon;
grant execute on function public.airvalet_makers_names_get() to authenticated;

-- Every 15 min: past days and today's flights that left more than 30 min ago are deleted.
select cron.unschedule(jobid) from cron.job where jobname = 'airvalet-makers-names-purge';
select cron.schedule('airvalet-makers-names-purge', '*/15 * * * *', $$
  delete from public.airvalet_makers_names
   where service_date < (now() at time zone 'America/New_York')::date
      or (service_date = (now() at time zone 'America/New_York')::date and dep_time ~ '^\d{1,2}:\d{2}'
          and service_date + dep_time::time + interval '30 minutes' < now() at time zone 'America/New_York')$$);

commit;

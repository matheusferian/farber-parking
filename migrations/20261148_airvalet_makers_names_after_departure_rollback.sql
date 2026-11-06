-- Back to 20261147: names of today stay until the end of the day.
begin;
create or replace function public.airvalet_makers_names_get()
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare v_today date := (now() at time zone 'America/New_York')::date;
begin
  perform public.airvalet_portal_require_ops();
  return coalesce((select jsonb_agg(jsonb_build_object('d', case when n.service_date = v_today then 0 else 1 end,
            'name', n.name, 'flight', n.flight, 'time', n.dep_time, 'dest', n.dest) order by n.service_date, n.dep_time, n.name)
     from public.airvalet_makers_names n where n.service_date in (v_today, v_today + 1)), '[]'::jsonb);
end $function$;
select cron.unschedule(jobid) from cron.job where jobname = 'airvalet-makers-names-purge';
select cron.schedule('airvalet-makers-names-purge', '10 4,5 * * *',
  $$delete from public.airvalet_makers_names where service_date < (now() at time zone 'America/New_York')::date$$);
commit;

-- Security review 2026-11-06 (owner: "segurança máxima" on the Makers robot).
--  1. One robot run at a time: a lock row with an expiry (service role only).
--  2. Robot readings (airvalet_manifest_scans, mode makers_sync) older than 14 days are deleted daily.
--  3. Name list: only valid HH:MM times are compared (a bad time can never break the RPC or the purge).
begin;
set local lock_timeout = '5s';

create table if not exists public.airvalet_robot_locks (name text primary key, locked_until timestamptz not null);
alter table public.airvalet_robot_locks enable row level security;
revoke all on table public.airvalet_robot_locks from public, anon, authenticated;

create or replace function public.airvalet_robot_lock(p_name text, p_secs integer)
 returns boolean language plpgsql security definer set search_path to ''
as $function$
declare v int;
begin
  insert into public.airvalet_robot_locks as l (name, locked_until) values (p_name, now() + make_interval(secs => least(greatest(p_secs, 10), 300)))
  on conflict (name) do update set locked_until = excluded.locked_until where l.locked_until < now();
  get diagnostics v = row_count;
  return v > 0;
end $function$;
create or replace function public.airvalet_robot_unlock(p_name text)
 returns void language sql security definer set search_path to ''
as $function$ update public.airvalet_robot_locks set locked_until = now() - interval '1 second' where name = p_name $function$;
revoke all on function public.airvalet_robot_lock(text, integer) from public, anon, authenticated;
revoke all on function public.airvalet_robot_unlock(text) from public, anon, authenticated;
grant execute on function public.airvalet_robot_lock(text, integer) to service_role;
grant execute on function public.airvalet_robot_unlock(text) to service_role;

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
       or (n.service_date = v_today and (n.dep_time !~ '^([01]?\d|2[0-3]):[0-5]\d$' or v_today + n.dep_time::time + interval '30 minutes' >= v_now))), '[]'::jsonb);
end $function$;
revoke all on function public.airvalet_makers_names_get() from public, anon;
grant execute on function public.airvalet_makers_names_get() to authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'airvalet-makers-names-purge';
select cron.schedule('airvalet-makers-names-purge', '*/15 * * * *', $$
  delete from public.airvalet_makers_names
   where service_date < (now() at time zone 'America/New_York')::date
      or (service_date = (now() at time zone 'America/New_York')::date and dep_time ~ '^([01]?\d|2[0-3]):[0-5]\d$'
          and service_date + dep_time::time + interval '30 minutes' < now() at time zone 'America/New_York')$$);

select cron.unschedule(jobid) from cron.job where jobname = 'airvalet-makers-scans-purge';
select cron.schedule('airvalet-makers-scans-purge', '20 9 * * *', $$
  delete from public.airvalet_manifest_scans where usage->>'mode' = 'makers_sync' and created_at < now() - interval '14 days'$$);

commit;

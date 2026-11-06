-- Owner 2026-11-06: tomorrow's (and today's) Makers departures from FXE, NAME ONLY, kept for one day so the
-- check-in name field can suggest them ("P" → PEDRO AUGUSTO). Read from Makers Air Suite by makers-sync
-- (read-only). No phone, e-mail, documents or booking data. Rows older than today (Fort Lauderdale) are
-- deleted by the robot on every run and by a nightly job; the RPC never returns them.
begin;
set local lock_timeout = '5s';

create table if not exists public.airvalet_makers_names (
  service_date date not null,
  name text not null check (char_length(name) between 2 and 80),
  flight text not null default '',
  dep_time text not null default '',
  dest text not null default '',
  created_at timestamptz not null default now(),
  primary key (service_date, name, flight)
);
alter table public.airvalet_makers_names enable row level security;
revoke all on table public.airvalet_makers_names from public, anon, authenticated;

-- Staff phones / iPad (ops roles only, not the TV): today's and tomorrow's names.
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
revoke all on function public.airvalet_makers_names_get() from public, anon;
grant execute on function public.airvalet_makers_names_get() to authenticated;

-- Nightly purge (~12:10 AM Fort Lauderdale, EST or EDT): yesterday's names are gone.
select cron.unschedule(jobid) from cron.job where jobname = 'airvalet-makers-names-purge';
select cron.schedule('airvalet-makers-names-purge', '10 4,5 * * *',
  $$delete from public.airvalet_makers_names where service_date < (now() at time zone 'America/New_York')::date$$);

commit;

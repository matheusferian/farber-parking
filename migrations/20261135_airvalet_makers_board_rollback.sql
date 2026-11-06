-- Rollback of 20261135_airvalet_makers_board.sql: removes the TV board function and restores
-- airvalet_manifest_latest() to "latest reading first" (20261134).
begin;
set local lock_timeout = '5s';
drop function if exists public.airvalet_makers_board();
create or replace function public.airvalet_manifest_latest()
 returns jsonb language plpgsql stable security definer set search_path to ''
as $function$
declare v jsonb;
begin
  perform public.airvalet_portal_require_ops();
  select jsonb_build_object('created_at', s.created_at, 'service_date', s.service_date,
           'ok', coalesce((s.usage->>'ok')::boolean, false), 'result', s.result)
    into v
    from public.airvalet_manifest_scans s
   where s.usage->>'mode' = 'makers_sync'
     and s.service_date >= (now() at time zone 'America/New_York')::date
   order by s.created_at desc limit 1;
  return v;
end $function$;
commit;

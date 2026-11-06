-- AirValet — dashboard Ready button (owner 2026-11-06): one read-only call that lists the
-- active passengers the team marked Ready on the valet pass (airvalet_pass_state.ready_at).
-- Same access rule as airvalet_pass_state_get (ops roles only). Rollback: 20261120_airvalet_pass_ready_ids_rollback.sql
begin;
set local lock_timeout = '5s';
create or replace function public.airvalet_pass_ready_ids()
 returns bigint[]
 language plpgsql
 stable
 security definer
 set search_path to ''
as $function$
begin
  perform public.airvalet_portal_require_ops();
  return coalesce((select array_agg(s.passenger_id order by s.passenger_id)
                     from public.airvalet_pass_state s
                     join public.passengers p on p.id = s.passenger_id
                    where s.ready_at is not null and p.status not in ('DELIVERED', 'ARCHIVED')), '{}'::bigint[]);
end $function$;
revoke all on function public.airvalet_pass_ready_ids() from public, anon;
grant execute on function public.airvalet_pass_ready_ids() to authenticated;
commit;

-- Rollback for 20260901_revoke_anon_execute_on_phase5_functions.sql.
-- Restores the exact grants that migration removed — the broader
-- (unintended but harmless, per that migration's own notes) grant state
-- these three functions had immediately before the hardening pass.

grant execute on function public.current_user_role() to public;
grant execute on function public.current_user_role() to anon;

grant execute on function public.set_user_role(uuid, public.account_role) to public;
grant execute on function public.set_user_role(uuid, public.account_role) to anon;

grant execute on function public.get_tv_mode_passengers() to anon;

-- Rollback for 20260901_create_user_profiles_and_roles.sql.
-- Removes every object that migration created. Does not touch any other
-- table. Run the companion 20260901_restrict_tv_only_role_rollback.sql
-- FIRST if that migration was also applied, since it depends on
-- current_user_role() defined here.

drop function if exists public.set_user_role(uuid, public.account_role);
drop function if exists public.current_user_role();
drop table if exists public.user_profiles;
drop type if exists public.account_role;

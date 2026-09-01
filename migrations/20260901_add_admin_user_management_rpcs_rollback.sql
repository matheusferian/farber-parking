-- Rollback for 20260901_add_admin_user_management_rpcs.sql.
-- Drops all three RPCs. Does not touch user_profiles, is_active, or any
-- other function.

drop function if exists public.admin_create_user_profile(uuid, text, text, public.account_role);
drop function if exists public.admin_set_user_active(uuid, boolean);
drop function if exists public.admin_delete_user_profile(uuid);

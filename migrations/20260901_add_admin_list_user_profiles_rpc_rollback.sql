-- Rollback for 20260901_add_admin_list_user_profiles_rpc.sql.
-- Drops the ADMIN-only listing RPC. Does not touch user_profiles, its
-- RLS policies, or any other function.

drop function if exists public.admin_list_user_profiles();

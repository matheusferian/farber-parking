-- Rollback for 20260901_add_tv_mode_passengers_rpc.sql.
-- Drops the dedicated TV Mode read RPC. Does not touch user_profiles,
-- current_user_role(), set_user_role(), or any RLS policy — those are
-- owned by the other two Phase 5 migrations and are rolled back
-- independently via their own paired rollback files.
--
-- Safe to run on its own: dropping this function does not restore direct
-- passengers SELECT access for TV_ONLY (that block lives in
-- 20260901_restrict_tv_only_role.sql / its own rollback) — it only removes
-- the dedicated read path, which would leave TV Mode with no working data
-- source for TV_ONLY again until either this migration is re-applied or
-- 20260901_restrict_tv_only_role_rollback.sql is run.

drop function if exists public.get_tv_mode_passengers();

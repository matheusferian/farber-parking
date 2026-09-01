-- Phase 5 hardening follow-up — remove unnecessary anon EXECUTE grants.
--
-- Found during the read-only grants verification after applying
-- 20260901_add_tv_mode_passengers_rpc.sql: three security-sensitive
-- functions introduced in this phase carry broader EXECUTE grants than
-- intended. Root cause (confirmed by comparison): this Supabase project
-- auto-grants EXECUTE to anon/authenticated/service_role on every newly
-- created function via a default-privileges rule, independent of the
-- PUBLIC pseudo-role — `revoke ... from public` (used in each function's
-- own migration) only removes the PUBLIC grant, not each named role's own
-- separate default-privilege grant. Live grants confirmed immediately
-- before this migration:
--   current_user_role()                    — PUBLIC, anon, authenticated,
--                                             postgres, service_role
--   set_user_role(uuid, account_role)       — PUBLIC, anon, authenticated,
--                                             postgres, service_role
--   get_tv_mode_passengers()                — anon, authenticated,
--                                             postgres, service_role
--                                             (no PUBLIC grant — its own
--                                             migration's `revoke all
--                                             ... from public` already
--                                             handled that one)
--
-- Practical impact of the gap being closed here: none of these functions
-- were actually exploitable by an anon (unauthenticated) caller — each
-- one's own body independently checks auth.uid()/current_user_role() and
-- raises an exception before doing anything for a session with no real
-- user. This migration is defense-in-depth (least-privilege grants,
-- matching the "only necessary" bar the client asked for), not a fix for
-- an active hole.
--
-- Postgres note: revoking a role's own direct grant (`revoke ... from
-- anon`) does NOT remove access if the PUBLIC pseudo-role still holds the
-- same privilege — PUBLIC grants apply to every role in addition to their
-- own direct grants. So for current_user_role()/set_user_role(), both the
-- PUBLIC grant and anon's own separate grant must be revoked; for
-- get_tv_mode_passengers() only the anon-specific grant exists, so only
-- that one is revoked.
--
-- No function bodies changed, no RLS changed, no other function touched.
-- authenticated/service_role/postgres keep EXECUTE exactly as before —
-- confirmed by re-querying information_schema.routine_privileges
-- immediately after applying.

revoke execute on function public.current_user_role() from public;
revoke execute on function public.current_user_role() from anon;

revoke execute on function public.set_user_role(uuid, public.account_role) from public;
revoke execute on function public.set_user_role(uuid, public.account_role) from anon;

revoke execute on function public.get_tv_mode_passengers() from anon;

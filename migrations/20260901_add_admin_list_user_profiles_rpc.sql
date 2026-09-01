-- Phase 5 — User Access (Phase 1): ADMIN-only user listing RPC.
--
-- user_profiles_select_own (the only SELECT policy on user_profiles) is
-- `using (id = auth.uid())` — every account, ADMIN included, can only
-- read its own row today. This RPC gives ADMIN a narrow way to list every
-- account's non-sensitive fields, without broadening user_profiles' RLS
-- itself — consistent with this project's existing preference for
-- purpose-built SECURITY DEFINER RPCs over opened-up policies (same
-- pattern as get_tv_mode_passengers()).
--
-- Returns exactly the 5 fields the User Access UI needs: username,
-- display_name, role, is_protected, is_active, plus id (needed as the
-- target for set_user_role()/admin_set_user_active()/
-- admin_delete_user_profile() calls from that same UI). No email, no
-- Auth/password data, no other user_profiles column. The internal
-- @airvalet.local email is never returned by this function — the UI's
-- primary identity is always the username/display_name pair.
-- Depends on the is_active column added by
-- 20260901_add_user_active_status.sql — must be applied first.
--
-- Authorization uses "IS DISTINCT FROM 'ADMIN'" (require-a-specific-role
-- direction), which is the safe direction confirmed during the fail-open
-- audit: NULL IS DISTINCT FROM 'ADMIN' evaluates to true, so an unmapped/
-- NULL-role caller is correctly refused. This is the same pattern
-- set_user_role() already uses for its own caller check.

create or replace function public.admin_list_user_profiles()
returns table (
  id           uuid,
  username     text,
  display_name text,
  role         public.account_role,
  is_protected boolean,
  is_active    boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'admin_list_user_profiles: authentication required';
  end if;

  if public.current_user_role() is distinct from 'ADMIN' then
    raise exception 'admin_list_user_profiles: only ADMIN accounts may list user profiles';
  end if;

  return query
  select up.id, up.username, up.display_name, up.role, up.is_protected, up.is_active
  from public.user_profiles up
  order by up.created_at;
end;
$$;

revoke all on function public.admin_list_user_profiles() from public;
revoke execute on function public.admin_list_user_profiles() from anon;
grant execute on function public.admin_list_user_profiles() to authenticated;

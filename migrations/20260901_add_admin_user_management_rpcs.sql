-- Phase 5 — User Access (Create/Disable/Enable/Delete): the three
-- ADMIN-only, SECURITY DEFINER RPCs the admin-manage-user Edge Function
-- calls for every user_profiles-side write. Auth-side operations
-- (createUser/deleteUser/updateUserById ban) can only happen in the Edge
-- Function (Postgres cannot call the Auth Admin API) — but every
-- profile-side mutation still goes through a guarded RPC here, called
-- with the CALLER's own JWT (never the service-role key), so the
-- database independently re-verifies ADMIN authorization itself. Even if
-- the Edge Function's own ADMIN check had a bug, these RPCs would still
-- refuse a non-ADMIN caller — same defense-in-depth as every other
-- guarded function in this project, not a single point of trust.
--
-- Depends on the is_active column added by
-- 20260901_add_user_active_status.sql — must be applied first.

-- ── admin_create_user_profile() ──────────────────────────────────────
-- Called AFTER the Edge Function has already created the real Auth user
-- via the Admin API — this only inserts the matching profile row. If
-- this fails (most likely: a race-condition username collision that
-- slipped past the Edge Function's own pre-check, or an invalid role),
-- the Edge Function rolls back the just-created Auth account by calling
-- auth.admin.deleteUser() — see supabase/functions/admin-manage-user.
-- is_protected is hardcoded false and is_active hardcoded true here —
-- a newly created account is never protected, and starts enabled.
create or replace function public.admin_create_user_profile(
  p_id           uuid,
  p_username     text,
  p_display_name text,
  p_role         public.account_role
)
returns public.user_profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.user_profiles;
begin
  if auth.uid() is null then
    raise exception 'admin_create_user_profile: authentication required';
  end if;

  if public.current_user_role() is distinct from 'ADMIN' then
    raise exception 'admin_create_user_profile: only ADMIN accounts may create user profiles';
  end if;

  insert into public.user_profiles (id, username, display_name, role, is_protected, is_active)
  values (p_id, p_username, p_display_name, p_role, false, true)
  returning * into v_row;

  return v_row;
end;
$$;

-- ── admin_set_user_active() ──────────────────────────────────────────
-- Three protections, same pattern as set_user_role(): caller must be
-- ADMIN, a protected row can never be disabled (or re-enabled — it's
-- already always active and untouchable either way), and disabling the
-- last remaining active ADMIN is refused so the system can never end up
-- with zero usable ADMIN accounts.
create or replace function public.admin_set_user_active(
  p_id     uuid,
  p_active boolean
)
returns public.user_profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target    public.user_profiles%rowtype;
  v_remaining int;
  v_row       public.user_profiles;
begin
  if auth.uid() is null then
    raise exception 'admin_set_user_active: authentication required';
  end if;

  if public.current_user_role() is distinct from 'ADMIN' then
    raise exception 'admin_set_user_active: only ADMIN accounts may change active status';
  end if;

  select * into v_target from public.user_profiles where id = p_id for update;
  if not found then
    raise exception 'admin_set_user_active: target account % has no user_profiles row', p_id;
  end if;

  if v_target.is_protected then
    raise exception 'admin_set_user_active: this account is protected and its active status cannot be changed';
  end if;

  if not p_active and v_target.role = 'ADMIN' then
    select count(*) into v_remaining
    from public.user_profiles
    where role = 'ADMIN' and is_active = true and id <> p_id;
    if v_remaining = 0 then
      raise exception 'admin_set_user_active: cannot disable the last active ADMIN account';
    end if;
  end if;

  update public.user_profiles
     set is_active = p_active, updated_at = now()
   where id = p_id
  returning * into v_row;

  return v_row;
end;
$$;

-- ── admin_delete_user_profile() ──────────────────────────────────────
-- Same protected-row and last-ADMIN guards as admin_set_user_active().
-- Only removes the user_profiles row — the Edge Function calls this
-- FIRST (before deleting the Auth account), so even if the subsequent
-- Auth deletion fails, the account is already stripped of every
-- operational capability (current_user_role() has nothing to find).
create or replace function public.admin_delete_user_profile(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target    public.user_profiles%rowtype;
  v_remaining int;
begin
  if auth.uid() is null then
    raise exception 'admin_delete_user_profile: authentication required';
  end if;

  if public.current_user_role() is distinct from 'ADMIN' then
    raise exception 'admin_delete_user_profile: only ADMIN accounts may delete user profiles';
  end if;

  select * into v_target from public.user_profiles where id = p_id for update;
  if not found then
    raise exception 'admin_delete_user_profile: target account % has no user_profiles row', p_id;
  end if;

  if v_target.is_protected then
    raise exception 'admin_delete_user_profile: this account is protected and cannot be deleted';
  end if;

  if v_target.role = 'ADMIN' then
    select count(*) into v_remaining
    from public.user_profiles
    where role = 'ADMIN' and is_active = true and id <> p_id;
    if v_remaining = 0 then
      raise exception 'admin_delete_user_profile: cannot delete the last active ADMIN account';
    end if;
  end if;

  delete from public.user_profiles where id = p_id;
end;
$$;

revoke all on function public.admin_create_user_profile(uuid, text, text, public.account_role) from public;
revoke execute on function public.admin_create_user_profile(uuid, text, text, public.account_role) from anon;
grant execute on function public.admin_create_user_profile(uuid, text, text, public.account_role) to authenticated;

revoke all on function public.admin_set_user_active(uuid, boolean) from public;
revoke execute on function public.admin_set_user_active(uuid, boolean) from anon;
grant execute on function public.admin_set_user_active(uuid, boolean) to authenticated;

revoke all on function public.admin_delete_user_profile(uuid) from public;
revoke execute on function public.admin_delete_user_profile(uuid) from anon;
grant execute on function public.admin_delete_user_profile(uuid) to authenticated;

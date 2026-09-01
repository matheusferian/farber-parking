-- Rollback for 20260901_add_user_active_status.sql.
-- Restores current_user_role() to its pre-is_active body, then drops the
-- column. Run this before rolling back 20260901_create_user_profiles_and_roles.sql
-- if both are being reverted (same dependency direction as the other
-- Phase 5 rollbacks).

create or replace function public.current_user_role()
returns public.account_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.user_profiles where id = auth.uid();
$$;

alter table public.user_profiles drop column if exists is_active;

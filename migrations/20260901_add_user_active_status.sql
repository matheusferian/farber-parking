-- Phase 5 — User Access (Enable/Disable): active/inactive status.
--
-- Adds a single is_active column and folds it directly into
-- current_user_role() rather than teaching every RLS policy/RPC about a
-- second condition. Every fail-closed check already built in this phase
-- (current_user_role() IN ('ADMIN','IPAD_OPS','IPHONE_OPS','MANAGER'),
-- the two SECURITY DEFINER guard functions, get_tv_mode_passengers(),
-- set_user_role(), admin_list_user_profiles()) already treats a NULL
-- role as "deny" — so a disabled account (is_active = false) losing its
-- effective role here means every one of those checks denies it
-- immediately, automatically, with no further changes needed anywhere
-- else. This is the same reason Auth-level disable (a real GoTrue ban,
-- applied by the admin-manage-user Edge Function) and this column are
-- both required rather than either alone: the Edge Function applies
-- both together so Auth status and profile state cannot silently
-- diverge, and this column is what makes a disabled account's revocation
-- of operational access effective immediately, even mid-session, without
-- waiting for a token to expire or a new login to be blocked.

alter table public.user_profiles
  add column if not exists is_active boolean not null default true;

comment on column public.user_profiles.is_active is
  'false = disabled. current_user_role() returns NULL for a disabled account regardless of its stored role, so every existing fail-closed RLS policy and guarded RPC denies it immediately. The admin-manage-user Edge Function keeps this in sync with a real Auth-level ban (auth.admin.updateUserById ban_duration) so the two states never silently diverge.';

create or replace function public.current_user_role()
returns public.account_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.user_profiles where id = auth.uid() and is_active = true;
$$;

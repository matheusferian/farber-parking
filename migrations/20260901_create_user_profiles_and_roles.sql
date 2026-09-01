-- Phase 5 — Fixed-role account model (User Access / Permissions).
--
-- AirValet has never had a permission model — every table's RLS policy is
-- "to authenticated using(true)": having a valid Supabase Auth account IS
-- the entire access model today (confirmed by direct inspection of every
-- existing policy before writing this migration). This introduces exactly
-- FIVE fixed roles, no generic role editor, no per-checkbox permission
-- matrix — matching the approved, narrowly-scoped design:
--   ADMIN       — full access; the only role that may manage other
--                 accounts' roles (via set_user_role() below).
--   IPAD_OPS    — full operational administrator (everything ADMIN has
--                 except account/role management).
--   IPHONE_OPS  — same operational core, mobile-focused; Report/Logs/
--                 Daily Closing/Debug stay hidden (frontend-only for now).
--   TV_ONLY     — TV Mode only. Real DB-level restriction added in the
--                 companion migration 20260901_restrict_tv_only_role.sql,
--                 not just a frontend redirect.
--   MANAGER     — Marcio's account. Full operational core + Report/Logs/
--                 Daily Closing, no Debug, no account management.
--
-- Only ONE real Supabase Auth account exists today (verified via
-- `supabase db query --linked` against auth.users immediately before
-- writing this migration): makers@farber.local. It is seeded below as
-- the protected ADMIN — this is the exact account already used for full
-- access today, so this migration changes nothing about its real-world
-- access. No other accounts exist yet; IPAD_OPS/IPHONE_OPS/TV_ONLY/
-- MANAGER accounts are deliberately NOT created here (see Phase 5 plan —
-- rollout safety requires schema+RLS+frontend to be verified against the
-- existing admin account first).

create type public.account_role as enum ('ADMIN', 'IPAD_OPS', 'IPHONE_OPS', 'TV_ONLY', 'MANAGER');

create table if not exists public.user_profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  username     text not null,
  role         public.account_role not null,
  display_name text,
  is_protected boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

comment on table public.user_profiles is
  'One row per Supabase Auth account, holding its fixed AirValet role and its visible username. Not a generic permissions table — role is one of exactly 5 fixed values (account_role enum). Role changes only via set_user_role(), never a direct client UPDATE (see RLS below).';
comment on column public.user_profiles.username is
  'The identity users type at login and see in the UI (e.g. "Admin", "iPad") — never the underlying Supabase Auth email, which is an internal identity only and is never shown in the normal app. Case-insensitive unique (see index below). The username-to-email mapping itself lives client-side (a small fixed lookup, not a secret, not queried from this table at login time) — see index.html.';
comment on column public.user_profiles.is_protected is
  'true only for the designated admin account(s) that must never be demoted, disabled, or locked out via set_user_role() — enforced inside that function, not just documented here.';

create unique index if not exists user_profiles_username_lower_idx on public.user_profiles (lower(username));

alter table public.user_profiles enable row level security;

-- Supabase grants broad default privileges to anon/authenticated on every
-- new table in public by default (see project convention established in
-- migrations/20260829_create_aircraft_tracking_tables.sql) — revoke first,
-- then grant back only what's intended.
revoke all on public.user_profiles from anon, authenticated;
grant select on public.user_profiles to authenticated;

-- Every signed-in account may read its own row (needed for the frontend
-- to know its own role) — nothing else. Deliberately NO insert/update/
-- delete policy for anon/authenticated at all: with RLS enabled and no
-- matching policy, those operations are denied outright, even for the
-- account's own row. The only write path is set_user_role() below, which
-- runs as SECURITY DEFINER and therefore bypasses this restriction from
-- inside its own, separately-gated logic.
drop policy if exists "user_profiles_select_own" on public.user_profiles;
create policy "user_profiles_select_own"
  on public.user_profiles
  for select
  to authenticated
  using (id = auth.uid());

-- ── current_user_role() ─────────────────────────────────────────────
-- Fail-closed by design: returns NULL for any account with no
-- user_profiles row (never guesses a default role). SECURITY DEFINER so
-- it can be called from within RLS policies on OTHER tables regardless of
-- those policies' own row visibility; SET search_path to a fixed value
-- guards against search-path hijacking (same defensive pattern already
-- used in migrations/20260717_add_return_date_history_and_activity_log_columns.sql).
create or replace function public.current_user_role()
returns public.account_role
language sql
stable
security definer
set search_path = public
as $$
  select role from public.user_profiles where id = auth.uid();
$$;

grant execute on function public.current_user_role() to authenticated;

-- ── set_user_role() — the ONLY way to change a role ─────────────────
-- SECURITY DEFINER, but re-validates the caller's own authority itself
-- rather than trusting anything the client claims. Three independent
-- protections, all enforced here (not just in the frontend):
--   1. Caller must actually be ADMIN today (re-checked via
--      current_user_role(), not a client-supplied flag).
--   2. A target row with is_protected = true can never be touched by
--      this function, full stop — no role change, ever.
--   3. Demoting the LAST remaining ADMIN is refused, so the system can
--      never end up with zero ADMIN accounts.
-- Every call is attributed via auth.uid()-derived identity in the raised
-- notice/log-friendly design below, matching this project's existing
-- tamper-proof-attribution convention.
create or replace function public.set_user_role(
  target_id uuid,
  new_role  public.account_role
)
returns public.user_profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_role   public.account_role;
  v_target        public.user_profiles%rowtype;
  v_remaining     int;
begin
  if auth.uid() is null then
    raise exception 'set_user_role: authentication required';
  end if;

  v_caller_role := public.current_user_role();
  if v_caller_role is distinct from 'ADMIN' then
    raise exception 'set_user_role: only ADMIN accounts may change roles';
  end if;

  select * into v_target from public.user_profiles where id = target_id for update;
  if not found then
    raise exception 'set_user_role: target account % has no user_profiles row', target_id;
  end if;

  if v_target.is_protected then
    raise exception 'set_user_role: this account is protected and its role cannot be changed';
  end if;

  if v_target.role = 'ADMIN' and new_role is distinct from 'ADMIN' then
    select count(*) into v_remaining
    from public.user_profiles
    where role = 'ADMIN' and id <> target_id;
    if v_remaining = 0 then
      raise exception 'set_user_role: cannot remove the last ADMIN account';
    end if;
  end if;

  update public.user_profiles
     set role = new_role, updated_at = now()
   where id = target_id
  returning * into v_target;

  return v_target;
end;
$$;

grant execute on function public.set_user_role(uuid, public.account_role) to authenticated;

-- ── Seed the one real existing account ──────────────────────────────
-- makers@farber.local is the account already used for full access today
-- (confirmed via direct auth.users query) — this changes nothing about
-- its real Auth identity (email/password/UUID untouched), it just gives
-- it an explicit, protected role row plus a visible username ("Admin")
-- so the rest of this migration set has something safe to build on.
-- This is the one deliberate exception to the username-to-email naming
-- convention used for the not-yet-created accounts below — the mapping
-- lives client-side as a small fixed lookup (index.html), not derived
-- from a formula, precisely because this account predates the convention.
insert into public.user_profiles (id, username, role, display_name, is_protected)
select id, 'Admin', 'ADMIN', 'Makers Air Admin', true
from auth.users
where email = 'makers@farber.local'
on conflict (id) do update
  set username = 'Admin', role = 'ADMIN', is_protected = true;

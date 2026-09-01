-- Phase 5 account provisioning — iPad (IPAD_OPS) profile row.
--
-- The Auth account itself (ipad@airvalet.local) was created manually by
-- the project owner, outside of any migration or tooling here — this
-- migration only maps the existing account to its AirValet role and
-- visible username, the same read-then-insert pattern used to seed the
-- Admin profile in 20260901_create_user_profiles_and_roles.sql. No Auth
-- credentials are created, read, or modified by this migration.
--
-- Confirmed immediately before writing this migration: exactly one
-- auth.users row exists for ipad@airvalet.local
-- (id b293f503-96ea-4afe-a13a-8bda69f95612), email already confirmed,
-- a password is set. auth.users itself has exactly 2 rows total
-- (makers@farber.local, ipad@airvalet.local) — no duplicates, no
-- unexpected accounts.

insert into public.user_profiles (id, username, role, display_name, is_protected)
select id, 'iPad', 'IPAD_OPS', 'iPad', false
from auth.users
where email = 'ipad@airvalet.local'
on conflict (id) do update
  set username = 'iPad', role = 'IPAD_OPS', display_name = 'iPad', is_protected = false;

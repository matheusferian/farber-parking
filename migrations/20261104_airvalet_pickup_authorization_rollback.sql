-- Rollback of 20261104: drops the guard and the pickup/release columns.
-- WARNING: authorizations and release records written since 20261104 are lost;
-- export them first (select id, ticket, pickup_auth_*, released_* from passengers
-- where pickup_auth_name is not null or released_to_name is not null).
begin;
drop trigger if exists airvalet_pickup_release_guard on public.passengers;
drop function if exists public.airvalet_pickup_release_guard();
alter table public.passengers drop constraint if exists passengers_pickup_auth_check;
alter table public.passengers
  drop column if exists pickup_auth_name, drop column if exists pickup_auth_phone,
  drop column if exists pickup_auth_location, drop column if exists pickup_auth_notes,
  drop column if exists pickup_auth_at, drop column if exists pickup_auth_by,
  drop column if exists released_to_name, drop column if exists released_to_kind,
  drop column if exists released_id_checked, drop column if exists released_by,
  drop column if exists released_at;
commit;

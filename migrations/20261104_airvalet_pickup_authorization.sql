-- New Check-in v2 (branch feature/checkin-v2, owner approval required before prod):
-- someone other than the guest may pick up the car. The authorization lives on
-- the same ticket (no second check-in, nothing texted to that person). At
-- delivery the team records who took the car after checking a photo ID; the
-- database refuses a delivery of a ticket with an active authorization unless
-- that ID check was recorded. Having the valet pass link is never enough.
-- Additive only: new nullable columns, one trigger. Existing rows unchanged.
begin;
alter table public.passengers
  add column if not exists pickup_auth_name     text,
  add column if not exists pickup_auth_phone    text,
  add column if not exists pickup_auth_location text,
  add column if not exists pickup_auth_notes    text,
  add column if not exists pickup_auth_at       timestamptz,
  add column if not exists pickup_auth_by       text,
  add column if not exists released_to_name     text,
  add column if not exists released_to_kind     text,
  add column if not exists released_id_checked  boolean,
  add column if not exists released_by          text,
  add column if not exists released_at          timestamptz;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'passengers_pickup_auth_check') then
    alter table public.passengers add constraint passengers_pickup_auth_check check (
      (pickup_auth_name is null or length(pickup_auth_name) between 1 and 80)
      and (pickup_auth_phone is null or pickup_auth_phone ~ '^[0-9]{10}$')
      and (pickup_auth_location is null or length(pickup_auth_location) <= 40)
      and (pickup_auth_notes is null or length(pickup_auth_notes) <= 500)
      and (released_to_kind is null or released_to_kind in ('GUEST', 'AUTHORIZED'))
      and (released_to_name is null or length(released_to_name) <= 80));
  end if;
end $$;

create or replace function public.airvalet_pickup_release_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  -- Reopened (DELIVERED → anything else): the old release record no longer counts,
  -- so the next delivery needs a new photo-ID check.
  if tg_op = 'UPDATE' and old.status = 'DELIVERED' and new.status is distinct from 'DELIVERED' then
    new.released_to_name := null; new.released_to_kind := null; new.released_id_checked := null;
    new.released_by := null; new.released_at := null;
  end if;
  if new.status = 'DELIVERED' and (tg_op = 'INSERT' or old.status is distinct from 'DELIVERED')
     and nullif(btrim(coalesce(new.pickup_auth_name, '')), '') is not null
     and (coalesce(new.released_id_checked, false) = false or nullif(btrim(coalesce(new.released_to_name, '')), '') is null) then
    raise exception 'AUTHORIZED_PICKUP_ID_REQUIRED: record who took the car and the ID check before delivering'
      using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function public.airvalet_pickup_release_guard() from public;

drop trigger if exists airvalet_pickup_release_guard on public.passengers;
create trigger airvalet_pickup_release_guard
  before insert or update of status on public.passengers
  for each row execute function public.airvalet_pickup_release_guard();

-- Who authorized / who released and when come from the signed-in session, not
-- from the client: a device cannot record another staff member's name.
create or replace function public.airvalet_pickup_stamp()
returns trigger language plpgsql set search_path = '' as $$
declare v_who text := nullif(btrim(coalesce(auth.jwt() ->> 'email', '')), '');
begin
  if tg_op = 'INSERT' or new.pickup_auth_name is distinct from old.pickup_auth_name
     or new.pickup_auth_phone is distinct from old.pickup_auth_phone
     or new.pickup_auth_location is distinct from old.pickup_auth_location
     or new.pickup_auth_notes is distinct from old.pickup_auth_notes then
    if new.pickup_auth_name is null then
      new.pickup_auth_by := null; new.pickup_auth_at := null;
    else
      new.pickup_auth_by := coalesce(v_who, new.pickup_auth_by); new.pickup_auth_at := now();
    end if;
  end if;
  if tg_op = 'INSERT' or new.released_to_name is distinct from old.released_to_name
     or new.released_id_checked is distinct from old.released_id_checked then
    if new.released_to_name is null and new.released_id_checked is null then
      new.released_by := null; new.released_at := null;
    else
      new.released_by := coalesce(v_who, new.released_by); new.released_at := now();
    end if;
  end if;
  return new;
end $$;
revoke all on function public.airvalet_pickup_stamp() from public;

drop trigger if exists airvalet_pickup_stamp on public.passengers;
create trigger airvalet_pickup_stamp
  before insert or update of pickup_auth_name, pickup_auth_phone, pickup_auth_location, pickup_auth_notes, released_to_name, released_id_checked
  on public.passengers
  for each row execute function public.airvalet_pickup_stamp();
commit;

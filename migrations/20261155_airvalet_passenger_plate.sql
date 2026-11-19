-- Owner 2026-11-19 ("pode anotar a placa dele também", "Sim, pode criar"): the car's plate on the ticket,
-- read by the car AI from the rear photo and saved only when staff tap "Looks right". Additive only.
-- Rollback: 20261155_airvalet_passenger_plate_rollback.sql
begin;
set local lock_timeout = '5s';
alter table public.passengers add column if not exists plate text check (plate is null or plate ~ '^[A-Z0-9 -]{1,10}$');
alter table public.passengers add column if not exists plate_state text check (plate_state is null or char_length(plate_state) between 2 and 20);
comment on column public.passengers.plate is 'Plate as printed (upper case), from the car AI after staff confirm, or typed by staff. Owner 2026-11-19.';
commit;

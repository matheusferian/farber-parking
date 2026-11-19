-- Rollback of 20261155: removes the plate columns (and any plates saved since).
begin;
set local lock_timeout = '5s';
alter table public.passengers drop column if exists plate_state;
alter table public.passengers drop column if exists plate;
commit;

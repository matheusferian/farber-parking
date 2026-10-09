-- Rollback for 20261010_add_passenger_return_operator.sql.
-- Drops the return operator values, captured instructions and review
-- acknowledgements recorded since the migration. The legacy flags keep the
-- values they had at rollback time (they were kept in sync), and the
-- activity_log history of the edits stays.
begin;
drop function if exists public.airvalet_return_review_ack(bigint, text);
drop view if exists public.airvalet_return_reviews;
drop table if exists public.airvalet_return_review_acks;
drop trigger if exists passengers_capture_legacy_instructions on public.passengers;
drop function if exists public.airvalet_capture_legacy_instructions();
drop table if exists public.airvalet_return_instructions;
alter table public.passengers drop constraint if exists passengers_return_flags_consistent;
drop trigger if exists passengers_sync_return_operator on public.passengers;
drop function if exists public.airvalet_sync_return_operator();
drop function if exists public.airvalet_initial_return_operator(text, boolean, boolean);
drop function if exists public.airvalet_pickup_location(text, boolean);
drop function if exists public.airvalet_return_location(text);
drop function if exists public.airvalet_departure_operator(text);
alter table public.passengers drop column if exists customs_exception_requested_at;
alter table public.passengers drop column if exists return_operator;
commit;

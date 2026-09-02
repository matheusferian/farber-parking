-- Delivery at Customs — independent operational flag.
--
-- Additive only: one boolean column on the existing `passengers` table,
-- same pattern as 20260712_add_customs_communication_fields.sql. Each
-- check-in is already its own row, so this is naturally trip-scoped.
-- Safe to run more than once; never overwrites existing passenger data.
--
-- Deliberately NOT the same thing as `delivery_type` (which records how a
-- vehicle was ACTUALLY delivered, decided by staff at the moment they mark
-- a passenger DELIVERED — see delivery_type='CUSTOMS' in buildKeyTicketXml
-- callers) and NOT the same thing as `loc` (the vehicle's CURRENT physical
-- location). `delivery_at_customs` is the passenger's REQUESTED delivery
-- destination, captured at New Entry / Edit time, before the vehicle ever
-- returns — see DECISIONS.md for the full reasoning.

alter table public.passengers add column if not exists delivery_at_customs boolean not null default false;

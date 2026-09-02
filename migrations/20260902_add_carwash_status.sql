-- Carwash status — independent optional field.
--
-- Additive only: one nullable text column on the existing `passengers`
-- table, same pattern as `delivery_type` (nullable text, no default,
-- informal enum enforced in app code, not a DB check constraint).
-- Safe to run more than once; never overwrites existing passenger data.
--
-- Values: NULL | 'CARWASH' | 'SEND_PRICE' | 'WASHED'. Deliberately its
-- own column, independent of delivery_at_customs/delivery_type/status/
-- loc — never derived from or written by any of those.

alter table public.passengers add column if not exists carwash_status text;

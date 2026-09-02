-- Rollback for 20260902_add_delivery_at_customs_flag.sql
-- Drops the delivery_at_customs column. Destructive to any values already
-- set on that column (all boolean, no other data loss) — only run this if
-- the Delivery at Customs feature itself is being reverted.

alter table public.passengers drop column if exists delivery_at_customs;

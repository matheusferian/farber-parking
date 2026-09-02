-- Rollback for 20260902_add_carwash_status.sql
-- Drops the carwash_status column. Destructive to any values already set
-- on that column — only run this if the Carwash feature is being reverted.

alter table public.passengers drop column if exists carwash_status;

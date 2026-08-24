-- Rollback for 20260714_create_contact_sync_tables.sql
--
-- Drops both new tables (and, with them, their indexes, RLS policies, and
-- the three triggers — two on contact_sync_batches, one on
-- contact_sync_items — which are all owned by their table and removed
-- automatically by DROP TABLE). Also explicitly drops all three trigger
-- functions, since functions are independent objects not owned by any
-- table and are NOT removed automatically by DROP TABLE.
--
-- Does NOT touch `passengers`, `activity_log`, `daily_closing_reports`, or
-- any other existing table.
--
-- Run this only if you need to fully undo the Daily Contact Sync database
-- change. This permanently deletes all recorded sync batches/items
-- (baseline history, confirmed-sync history) — the underlying passenger
-- records themselves are never touched or deleted.
--
-- Wrapped in a single transaction: if any statement fails, the whole
-- rollback is rolled back rather than leaving the schema half-undone.

BEGIN;

drop table if exists public.contact_sync_items;
drop table if exists public.contact_sync_batches;
drop function if exists public.contact_sync_batches_protect_insert();
drop function if exists public.contact_sync_batches_protect_update();
drop function if exists public.contact_sync_items_protect_insert();

COMMIT;

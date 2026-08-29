-- Rollback for 20260829_create_aircraft_tracking_tables.sql
-- Removes every object that migration created. Safe to run even if some
-- objects were never created (all drops are IF EXISTS). Does not touch
-- any other table in this database.

drop function if exists public.upsert_aircraft_observations(jsonb);
drop function if exists public.complete_aircraft_refresh(text, boolean, integer, text);
drop function if exists public.claim_aircraft_refresh(text, integer, integer);

drop view if exists public.aircraft_live_state_computed;

drop table if exists public.aircraft_refresh_control;
drop table if exists public.aircraft_live_state;

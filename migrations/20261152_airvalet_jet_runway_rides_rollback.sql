-- Rollback of 20261152_airvalet_jet_runway_rides.sql (removes the Jet Runway rides module; touches nothing else).
drop function if exists public.airvalet_ride_tip_claim(text);
drop function if exists public.airvalet_ride_mark_ready(text);
drop function if exists public.airvalet_rides_board();
drop function if exists public.airvalet_ride_set(uuid, text, text);
drop function if exists public.airvalet_ride_create(text, text, text);
drop table if exists public.airvalet_ride_messages;
drop table if exists public.airvalet_rides;

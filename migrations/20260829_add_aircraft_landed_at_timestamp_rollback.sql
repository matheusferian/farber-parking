-- Rollback for 20260829_add_aircraft_landed_at_timestamp.sql
-- Restores upsert_aircraft_observations to the pre-landed_at definition
-- verbatim, then drops the column. Safe to run more than once.
--
-- Column dropped LAST (after the function no longer references it) so a
-- partial rollback never leaves the function referencing a missing column.

create or replace function public.upsert_aircraft_observations(p_worker_id text, p_observations jsonb)
returns integer
language plpgsql
set search_path = public
as $$
declare
  v_row_count integer;
begin
  insert into public.aircraft_live_state (
    registration, icao_hex, callsign,
    latitude, longitude, altitude_ft, is_on_ground,
    ground_speed_kt, track_deg, vertical_rate_fpm,
    distance_to_fxe_nm,
    last_message_at, last_position_at,
    provider, polled_at, updated_at
  )
  select
    o.registration, o.icao_hex, o.callsign,
    o.latitude, o.longitude, o.altitude_ft, o.is_on_ground,
    o.ground_speed_kt, o.track_deg, o.vertical_rate_fpm,
    o.distance_to_fxe_nm,
    o.last_message_at, o.last_position_at,
    o.provider, o.polled_at, now()
  from jsonb_to_recordset(p_observations) as o(
    registration text, icao_hex text, callsign text,
    latitude double precision, longitude double precision,
    altitude_ft integer, is_on_ground boolean,
    ground_speed_kt real, track_deg real, vertical_rate_fpm integer,
    distance_to_fxe_nm real,
    last_message_at timestamptz, last_position_at timestamptz,
    provider text, polled_at timestamptz
  )
  where exists (
    select 1
    from public.aircraft_refresh_control c
    where c.id = 'adsb'
      and c.lock_owner = p_worker_id
      and c.lock_until > now()
  )
  on conflict (registration) do update set
    icao_hex                     = excluded.icao_hex,
    callsign                     = excluded.callsign,
    latitude                     = excluded.latitude,
    longitude                    = excluded.longitude,
    altitude_ft                  = excluded.altitude_ft,
    is_on_ground                 = excluded.is_on_ground,
    ground_speed_kt              = excluded.ground_speed_kt,
    track_deg                    = excluded.track_deg,
    vertical_rate_fpm            = excluded.vertical_rate_fpm,
    previous_distance_to_fxe_nm  = public.aircraft_live_state.distance_to_fxe_nm,
    distance_to_fxe_nm           = excluded.distance_to_fxe_nm,
    last_message_at              = excluded.last_message_at,
    last_position_at             = excluded.last_position_at,
    provider                     = excluded.provider,
    polled_at                    = excluded.polled_at,
    updated_at                   = now();

  get diagnostics v_row_count = row_count;
  return v_row_count;
end;
$$;

comment on function public.upsert_aircraft_observations(text, jsonb) is
  'Lease-fenced atomic multi-row upsert. On conflict, shifts the existing distance_to_fxe_nm into previous_distance_to_fxe_nm inside the same statement — never a client-side read-then-write. On first insert for a registration, previous_distance_to_fxe_nm stays NULL. Only called for aircraft actually present in that cycle''s ac[]; absent aircraft are left completely untouched by design (see aircraft_live_state_computed for how their freshness ages naturally without a write). Returns the number of rows actually written; a caller that always passes a non-empty p_observations array can treat 0 as unambiguous proof of being fenced out.';

-- Re-create the view WITHOUT landed_at. This must run BEFORE the DROP
-- COLUMN below (Postgres refuses to drop a column a view still depends
-- on). CREATE OR REPLACE VIEW cannot be used here: Postgres only allows
-- CREATE OR REPLACE to APPEND new trailing columns, never to remove an
-- existing one (confirmed while building the forward migration — the
-- exact same constraint that required an explicit column list there
-- also means removing landed_at requires DROP + CREATE, not REPLACE).
-- DROP VIEW removes its grants, so they are re-applied immediately
-- after, matching the original B.1 creation pattern (which also used
-- drop-then-create for this same view, not create-or-replace).
drop view if exists public.aircraft_live_state_computed;
create view public.aircraft_live_state_computed
with (security_invoker = true)
as
select
  s.registration, s.icao_hex, s.callsign,
  s.latitude, s.longitude, s.altitude_ft, s.is_on_ground,
  s.ground_speed_kt, s.track_deg, s.vertical_rate_fpm,
  s.distance_to_fxe_nm, s.previous_distance_to_fxe_nm,
  s.last_message_at, s.last_position_at,
  s.provider, s.polled_at, s.updated_at,
  case
    when s.last_position_at is null then 'NO_SIGNAL'
    when now() - s.last_position_at <= interval '80 seconds' then 'LIVE'
    when now() - s.last_position_at <= interval '180 seconds' then 'STALE'
    else 'NO_SIGNAL'
  end as freshness,
  case
    when s.last_position_at is null or now() - s.last_position_at > interval '180 seconds' then 'NO_SIGNAL'
    when now() - s.last_position_at > interval '80 seconds' then 'STALE'
    when s.is_on_ground and s.distance_to_fxe_nm is not null and s.distance_to_fxe_nm <= 3 then 'ON_GROUND_NEAR_FXE'
    when s.is_on_ground then 'ON_GROUND_AWAY'
    else 'AIRBORNE'
  end as physical_status,
  case
    when s.distance_to_fxe_nm is null or s.previous_distance_to_fxe_nm is null then 'UNKNOWN'
    when s.distance_to_fxe_nm < s.previous_distance_to_fxe_nm - 0.5 then 'DECREASING'
    when s.distance_to_fxe_nm > s.previous_distance_to_fxe_nm + 0.5 then 'INCREASING'
    else 'STABLE'
  end as distance_trend
from public.aircraft_live_state s;

comment on view public.aircraft_live_state_computed is
  'Read-time computation of freshness/physical_status/distance_trend from the raw absolute timestamps in aircraft_live_state — never stored, so these labels can never go stale-themselves during a provider outage. LIVE cutoff 80s, STALE/NO_SIGNAL 180s, 3nm near-FXE radius, 0.5nm trend hysteresis.';

revoke all on public.aircraft_live_state_computed from anon, authenticated;
grant select on public.aircraft_live_state_computed to authenticated;

alter table public.aircraft_live_state
  drop column if exists landed_at;

-- Rollback for 20260829_harden_aircraft_tracking_lease_fencing.sql
-- Restores the original B.1 unfenced upsert_aircraft_observations(jsonb)
-- verbatim. Only use this to deliberately revert to pre-fencing
-- behavior — not recommended, since it reopens the stale-write race the
-- forward migration fixes. Safe to run more than once.

drop function if exists public.upsert_aircraft_observations(text, jsonb);

create or replace function public.upsert_aircraft_observations(p_observations jsonb)
returns void
language sql
set search_path = public
as $$
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
$$;

comment on function public.upsert_aircraft_observations(jsonb) is
  'Atomic multi-row upsert for one provider batch cycle. On conflict, shifts the existing distance_to_fxe_nm into previous_distance_to_fxe_nm inside the same statement — never a client-side read-then-write. On first insert for a registration, previous_distance_to_fxe_nm stays NULL. Only called for aircraft actually present in that cycle''s ac[]; absent aircraft are left completely untouched by design (see aircraft_live_state_computed for how their freshness ages naturally without a write).';

revoke all on function public.upsert_aircraft_observations(jsonb) from public, anon, authenticated;
grant execute on function public.upsert_aircraft_observations(jsonb) to service_role;

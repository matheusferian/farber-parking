-- Live Aircraft Tracking — B.2 hardening: lease fencing for
-- upsert_aircraft_observations(). Found during real B.2 manual testing,
-- not part of the original B.1 migration (which this file does not
-- rewrite — B.1 is already applied/committed/pushed).
--
-- Gap: complete_aircraft_refresh() already checked `lock_owner =
-- p_worker_id` before releasing/recording the lease, but
-- upsert_aircraft_observations() had no ownership check of its own. A
-- worker whose lease expired mid-flight (e.g. stalled past lock_until)
-- could still land a write after a newer worker had already claimed the
-- lease and obtained fresher data — the check on complete_aircraft_refresh
-- was too late, since the stale data-plane mutation could already have
-- happened by the time that call runs.
--
-- Fix: fold the ownership+expiry check directly into the SAME INSERT
-- statement that performs the write, via a `WHERE EXISTS(...)` guard
-- evaluated as part of that one statement — not a separate
-- check-then-write pair of statements (which would reopen a
-- smaller-but-real race under READ COMMITTED, since each statement in a
-- session gets its own snapshot). If the exists() check fails at the
-- moment this single INSERT executes, zero rows are read from
-- jsonb_to_recordset()'s WHERE-filtered source, so zero rows are written
-- — atomically, in one statement, same as claim_aircraft_refresh's own
-- UPDATE...WHERE...RETURNING pattern.
--
-- The old unfenced single-argument upsert_aircraft_observations(jsonb) is
-- dropped — it must not remain callable after this migration.
--
-- Safe to run more than once.

drop function if exists public.upsert_aircraft_observations(jsonb);

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
  -- Lease fencing: the write only happens while p_worker_id is still the
  -- CURRENT lock_owner AND that lease has not expired. Evaluated as part
  -- of this single INSERT — not a prior separate SELECT.
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
  'Lease-fenced atomic multi-row upsert. Only writes while p_worker_id matches the CURRENT lock_owner in aircraft_refresh_control AND that lease has not expired (lock_until > now()) — checked via a WHERE EXISTS(...) folded into the same INSERT statement as the write itself, so a worker whose lease expired or was reclaimed mid-flight cannot land a stale write after the fact. Returns the number of rows actually written; a caller that always passes a non-empty p_observations array can treat 0 as unambiguous proof of being fenced out.';

revoke all on function public.upsert_aircraft_observations(text, jsonb) from public, anon, authenticated;
grant execute on function public.upsert_aircraft_observations(text, jsonb) to service_role;

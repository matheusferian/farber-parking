-- Live Aircraft Tracking — persisted landing timestamp (TV Mode LANDED
-- badge follow-up to C.2's DELAYED/ETA work).
--
-- Problem: aircraft_live_state_computed's physical_status='ON_GROUND_NEAR_FXE'
-- is a read-time SNAPSHOT (is_on_ground AND distance_to_fxe_nm<=3,
-- recomputed fresh every query) — there was no record of WHEN that
-- transition happened. A real aircraft commonly stops transmitting ADS-B
-- entirely once parked (engines off), so relying on the snapshot alone
-- would make a "just landed" badge silently decay to STALE/NO_SIGNAL and
-- vanish a few minutes after the landing it's supposed to be reporting —
-- the opposite of the intended behavior.
--
-- Fix: one new nullable column, set/preserved/cleared entirely inside the
-- existing lease-fenced upsert_aircraft_observations — no Edge Function
-- change needed, no new write path, no change to the claim/lease/fencing
-- mechanism itself.
--
--   1. aircraft_live_state.landed_at timestamptz, nullable, no default.
--   2. upsert_aircraft_observations: on a write where the NEW observation
--      is on-ground within 3nm of FXE, landed_at = COALESCE(existing
--      landed_at, this write's timestamp) — set once, on first detection,
--      never overwritten by subsequent still-on-ground writes (so the
--      "N MIN AGO" counter keeps counting from the true first landing,
--      not resetting every ~60s poll). On any OTHER write (airborne, or
--      on-ground-but-away from FXE), landed_at is cleared back to NULL —
--      so a same-day return leg on the same aircraft gets a fresh
--      timestamp instead of inheriting an earlier landing. An
--      absent-from-batch cycle writes nothing at all (existing
--      absence-preserves-row semantics, untouched by this migration), so
--      landed_at is naturally preserved through any gap in ADS-B
--      reception exactly like every other column already is.
--
-- aircraft_live_state_computed IS re-created below, text-unchanged from
-- its live definition (still `select s.*, ...`) — this is required, not
-- optional: a view's `s.*` is expanded to an explicit column list at
-- CREATE/CREATE OR REPLACE time and stays frozen after that; it does NOT
-- retroactively pick up a column added to the underlying table later.
-- Confirmed live during this migration's own rollout (landed_at was
-- correctly added to the table but absent from the view's query results
-- until this second CREATE OR REPLACE VIEW statement ran). Re-running the
-- identical SQL text is sufficient — no column list, grant, RLS, or
-- security_invoker change. No Edge Function, cron, pg_net, Vault,
-- scheduler auth, lease/fencing WHERE-EXISTS clause, or aircraft
-- configuration change.
--
-- Safe to run more than once (ADD COLUMN IF NOT EXISTS, CREATE OR REPLACE).

alter table public.aircraft_live_state
  add column if not exists landed_at timestamptz;

comment on column public.aircraft_live_state.landed_at is
  'First-detected timestamp of is_on_ground AND distance_to_fxe_nm<=3 (near FXE), set/preserved/cleared by upsert_aircraft_observations. NULL means not currently on the ground near FXE (either still airborne, on the ground elsewhere, or has since departed again). Deliberately NOT recomputed from the read-time physical_status snapshot — this is meant to persist even after the aircraft goes quiet post-landing, unlike freshness/physical_status/distance_trend.';

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
    provider, polled_at, updated_at,
    landed_at
  )
  select
    o.registration, o.icao_hex, o.callsign,
    o.latitude, o.longitude, o.altitude_ft, o.is_on_ground,
    o.ground_speed_kt, o.track_deg, o.vertical_rate_fpm,
    o.distance_to_fxe_nm,
    o.last_message_at, o.last_position_at,
    o.provider, o.polled_at, now(),
    case
      when o.is_on_ground and o.distance_to_fxe_nm is not null and o.distance_to_fxe_nm <= 3
        then now()
      else null
    end
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
  -- of this single INSERT — not a prior separate SELECT. Unchanged by
  -- this migration.
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
    updated_at                   = now(),
    landed_at                    = case
      when excluded.is_on_ground and excluded.distance_to_fxe_nm is not null and excluded.distance_to_fxe_nm <= 3
        then coalesce(public.aircraft_live_state.landed_at, excluded.landed_at)
      else null
    end;

  get diagnostics v_row_count = row_count;
  return v_row_count;
end;
$$;

comment on function public.upsert_aircraft_observations(text, jsonb) is
  'Lease-fenced atomic multi-row upsert. On conflict, shifts the existing distance_to_fxe_nm into previous_distance_to_fxe_nm inside the same statement — never a client-side read-then-write. On first insert for a registration, previous_distance_to_fxe_nm stays NULL. Only called for aircraft actually present in that cycle''s ac[]; absent aircraft are left completely untouched by design (see aircraft_live_state_computed for how their freshness ages naturally without a write). landed_at (2026-08-29, see 20260829_add_aircraft_landed_at_timestamp.sql) is set once on first is_on_ground+near-FXE detection, preserved across subsequent still-on-ground writes, and cleared back to NULL the moment the aircraft is next observed airborne or on the ground away from FXE — independent of the lease/fencing mechanism above. Returns the number of rows actually written; a caller that always passes a non-empty p_observations array can treat 0 as unambiguous proof of being fenced out.';

-- Re-create the view to expose landed_at. NOTE: CREATE OR REPLACE VIEW
-- requires every PRE-EXISTING output column to keep the same name in the
-- same position — it can only APPEND new columns at the end. A plain
-- `s.*` re-expansion was tried first and rejected by Postgres (42P16:
-- "cannot change name of view column \"freshness\" to \"landed_at\""),
-- because landed_at's position in the table's own column order (right
-- after updated_at, since that's where ALTER TABLE ADD COLUMN put it)
-- sits BEFORE the three CASE-computed columns in the SELECT list,
-- shifting their positions. Fixed by listing the original 17 base
-- columns explicitly (same names, same order, same positions 1-17), the
-- three CASE columns unchanged (same positions 18-20), and landed_at
-- appended as a genuinely new trailing column (position 21). Logic/
-- thresholds are otherwise byte-identical to the live definition.
create or replace view public.aircraft_live_state_computed
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
  end as distance_trend,
  s.landed_at
from public.aircraft_live_state s;

comment on view public.aircraft_live_state_computed is
  'Read-time computation of freshness/physical_status/distance_trend from the raw absolute timestamps in aircraft_live_state — never stored, so these labels can never go stale-themselves during a provider outage. LIVE cutoff 80s, STALE/NO_SIGNAL 180s (see 20260829_correct_aircraft_tracking_cadence_thresholds.sql), 3nm near-FXE radius, 0.5nm trend hysteresis. landed_at (2026-08-29, see 20260829_add_aircraft_landed_at_timestamp.sql) is passed through as-is — a persisted fact from upsert_aircraft_observations, deliberately NOT recomputed here, meant to survive even after freshness degrades to STALE/NO_SIGNAL post-landing.';

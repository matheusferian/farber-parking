-- Live Aircraft Tracking — Phase B.1 (database only, no provider calls yet).
-- Introduces two new tables, one computed view, and three RPCs, none of
-- which are wired into the app yet. index.html/styles.css/service-worker.js
-- are completely untouched by this migration.
--
-- Two tables, deliberately kept separate:
--   aircraft_live_state     — data-plane: one row per tracked aircraft,
--                             the most recent observation from the provider.
--   aircraft_refresh_control — control-plane: a single row that coordinates
--                             which worker (cron tick / manual invoke) is
--                             currently allowed to call the external
--                             provider, so concurrent callers never cause
--                             more than one external HTTP call per cycle.
--
-- aircraft_live_state intentionally holds ONLY aircraft/provider/geospatial
-- state — no OUTBOUND/RETURNING/APPROACHING-style operational status lives
-- here, because that classification depends on passenger.return_flight and
-- passenger.departure_time, which this migration and the future Edge
-- Function never query. That combination is a later, separate, pure
-- client-side function (see PROJECT.md, Live Aircraft Tracking).
--
-- Freshness/physical-state labels (freshness, physical_status,
-- distance_trend) are NOT stored columns — they're computed at read time
-- in aircraft_live_state_computed from absolute timestamps, specifically so
-- they can never go stale-themselves if the provider is down for a while
-- and no new writes happen.
--
-- Safe to run more than once (every object creation is guarded).

-- ── DATA PLANE ────────────────────────────────────────────────────────
create table if not exists public.aircraft_live_state (
  registration                  text primary key,
  icao_hex                      text not null,
  callsign                      text,
  latitude                      double precision,
  longitude                     double precision,
  altitude_ft                   integer,
  is_on_ground                  boolean not null default false,
  ground_speed_kt                real,
  track_deg                      real,
  vertical_rate_fpm             integer,

  distance_to_fxe_nm             real,
  previous_distance_to_fxe_nm    real,

  last_message_at                timestamptz,
  last_position_at               timestamptz,

  provider                       text not null default 'adsb.lol',
  polled_at                      timestamptz,
  updated_at                     timestamptz not null default now()
);

comment on table public.aircraft_live_state is
  'Data-plane cache: one row per tracked aircraft, most recent observation from the tracking provider. No operational/scheduling status lives here — see PROJECT.md, Live Aircraft Tracking.';

comment on column public.aircraft_live_state.polled_at is
  'Timestamp of the last successful provider cycle in which this specific aircraft was present in ac[]. Does not imply any field value changed since the previous poll — a stationary, continuously-transmitting aircraft updates this every cycle with identical position data.';

comment on column public.aircraft_live_state.previous_distance_to_fxe_nm is
  'Value of distance_to_fxe_nm as it stood immediately before the most recent observation — shifted atomically by upsert_aircraft_observations(). NULL until the aircraft has been observed at least twice.';

comment on column public.aircraft_live_state.last_message_at is
  'Absolute UTC timestamp of the last ADS-B message of any kind, derived once per batch from the provider''s own "now" field minus "seen" seconds — never recomputed against our own clock per-aircraft.';

comment on column public.aircraft_live_state.last_position_at is
  'Absolute UTC timestamp of the last valid position, derived once per batch from the provider''s own "now" field minus "seen_pos" seconds. This is the primary input for freshness/physical_status in aircraft_live_state_computed.';

alter table public.aircraft_live_state enable row level security;

drop policy if exists "aircraft_live_state_select_authenticated" on public.aircraft_live_state;
create policy "aircraft_live_state_select_authenticated"
  on public.aircraft_live_state
  for select
  to authenticated
  using (true);

-- Supabase grants broad default privileges (SELECT/INSERT/UPDATE/DELETE/
-- TRUNCATE/REFERENCES/TRIGGER) to anon and authenticated on every new
-- table in public by default — RLS's own per-command policy check would
-- still have blocked any actual write, but relying on that alone leaves
-- the GRANT layer needlessly permissive (defense-in-depth: if RLS were
-- ever accidentally disabled, those default grants would immediately
-- expose full read/write/delete/truncate). Revoke everything first, then
-- grant back only the one privilege actually intended.
revoke all on public.aircraft_live_state from anon, authenticated;
grant select on public.aircraft_live_state to authenticated;
-- No insert/update/delete grant/policy for authenticated — only
-- service_role (used internally by the Edge Function, which bypasses
-- RLS by design) ever writes to this table. anon has no grant at all —
-- SELECT correctly fails with `permission denied`, not silent 0 rows.

-- ── CONTROL PLANE ─────────────────────────────────────────────────────
create table if not exists public.aircraft_refresh_control (
  id                       text primary key,
  last_attempt_at          timestamptz,
  last_success_at          timestamptz,
  lock_until               timestamptz,
  lock_owner               text,
  last_provider_status     integer,
  last_error               text,
  consecutive_failures     integer not null default 0,
  updated_at               timestamptz not null default now()
);

comment on table public.aircraft_refresh_control is
  'Control-plane state: single-row lease/coordination record so concurrent Edge Function invocations (cron tick, manual invoke, future diagnostic trigger) never cause more than one external provider call within the cache TTL. Separate from aircraft_live_state (data-plane) by design.';

comment on column public.aircraft_refresh_control.last_success_at is
  'Timestamp of the last valid provider response — HTTP 200 with ac as an array, including a legitimately empty ac: []. Does NOT imply any of the configured aircraft had their aircraft_live_state row updated that cycle; it only means the provider call itself succeeded.';

comment on column public.aircraft_refresh_control.lock_until is
  'Lease expiry for the CURRENT refresh attempt only — concurrency/crash-safety, never provider rate-limit backoff. A 429 does not extend this; see last_error/last_provider_status for that signal instead.';

-- Same reasoning as aircraft_live_state, but no policy at all is created —
-- this table is invisible to anon/authenticated by design. Only
-- service_role (which bypasses RLS) reads or writes it.
alter table public.aircraft_refresh_control enable row level security;

-- Same default-grant correction as aircraft_live_state above, but with
-- nothing granted back — anon and authenticated should have zero
-- standing privilege here, not even SELECT.
revoke all on public.aircraft_refresh_control from anon, authenticated;

insert into public.aircraft_refresh_control (id)
values ('adsb')
on conflict (id) do nothing;

-- ── COMPUTED READ VIEW ────────────────────────────────────────────────
-- security_invoker = true is required here: without it, the view would
-- run with its owner's privileges by default and silently bypass RLS on
-- aircraft_live_state for anyone able to select the view. With it, the
-- querying role's own grants/RLS apply, exactly as if they queried the
-- table directly.
drop view if exists public.aircraft_live_state_computed;
create view public.aircraft_live_state_computed
with (security_invoker = true)
as
select
  s.*,
  case
    when s.last_position_at is null then 'NO_SIGNAL'
    when now() - s.last_position_at <= interval '30 seconds' then 'LIVE'
    when now() - s.last_position_at <= interval '180 seconds' then 'STALE'
    else 'NO_SIGNAL'
  end as freshness,
  case
    when s.last_position_at is null or now() - s.last_position_at > interval '180 seconds' then 'NO_SIGNAL'
    when now() - s.last_position_at > interval '30 seconds' then 'STALE'
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
  'Read-time computation of freshness/physical_status/distance_trend from the raw absolute timestamps in aircraft_live_state — never stored, so these labels can never go stale-themselves during a provider outage. 30s/180s/3nm/0.5nm thresholds are initial proposals, to be tuned in Phase B.5 against real flight data.';

-- Same default-grant correction as the base table.
revoke all on public.aircraft_live_state_computed from anon, authenticated;
grant select on public.aircraft_live_state_computed to authenticated;

-- ── ATOMIC LEASE / CLAIM RPC ──────────────────────────────────────────
-- Single UPDATE ... WHERE ... RETURNING — race-safety comes from ordinary
-- Postgres row-level locking under READ COMMITTED, not from a session-held
-- advisory lock spanning the external HTTP call (rejected design — see
-- PROJECT.md, Live Aircraft Tracking).
create or replace function public.claim_aircraft_refresh(
  p_worker_id text,
  p_lease_seconds integer default 20,
  p_cache_ttl_seconds integer default 60
)
returns table (claimed boolean, cache_is_fresh boolean, last_success_at timestamptz)
language plpgsql
set search_path = public
as $$
declare
  v_row public.aircraft_refresh_control%rowtype;
begin
  update public.aircraft_refresh_control
  set lock_until = now() + make_interval(secs => p_lease_seconds),
      lock_owner = p_worker_id,
      last_attempt_at = now(),
      updated_at = now()
  where id = 'adsb'
    and (public.aircraft_refresh_control.lock_until is null or public.aircraft_refresh_control.lock_until < now())
    and (public.aircraft_refresh_control.last_success_at is null or public.aircraft_refresh_control.last_success_at < now() - make_interval(secs => p_cache_ttl_seconds))
  returning * into v_row;

  if found then
    return query select true, false, v_row.last_success_at;
    return;
  end if;

  select * into v_row from public.aircraft_refresh_control where id = 'adsb';
  return query select
    false,
    (v_row.last_success_at is not null and v_row.last_success_at >= now() - make_interval(secs => p_cache_ttl_seconds)),
    v_row.last_success_at;
end;
$$;

comment on function public.claim_aircraft_refresh(text, integer, integer) is
  'Atomically attempts to claim the right to call the external tracking provider. Returns claimed=true only to the single caller that wins the race; all other concurrent callers immediately learn whether the existing cache is still fresh, without ever touching the provider themselves.';

revoke all on function public.claim_aircraft_refresh(text, integer, integer) from public, anon, authenticated;
grant execute on function public.claim_aircraft_refresh(text, integer, integer) to service_role;

-- ── LEASE COMPLETION RPC ──────────────────────────────────────────────
create or replace function public.complete_aircraft_refresh(
  p_worker_id text,
  p_success boolean,
  p_provider_status integer default null,
  p_error text default null
)
returns void
language plpgsql
set search_path = public
as $$
begin
  update public.aircraft_refresh_control
  set lock_until = null,
      lock_owner = null,
      last_success_at = case when p_success then now() else last_success_at end,
      last_provider_status = p_provider_status,
      last_error = case when p_success then null else p_error end,
      consecutive_failures = case when p_success then 0 else consecutive_failures + 1 end,
      updated_at = now()
  where id = 'adsb'
    and lock_owner = p_worker_id;
end;
$$;

comment on function public.complete_aircraft_refresh(text, boolean, integer, text) is
  'Releases the lease claimed by claim_aircraft_refresh(). The lock_owner = p_worker_id guard means only the worker that actually holds the current claim can release/complete it — a crashed worker whose lease already expired and was reclaimed by someone else cannot clobber the newer claim.';

revoke all on function public.complete_aircraft_refresh(text, boolean, integer, text) from public, anon, authenticated;
grant execute on function public.complete_aircraft_refresh(text, boolean, integer, text) to service_role;

-- ── OBSERVATION UPSERT RPC ────────────────────────────────────────────
-- Atomic multi-row upsert for everything observed in one provider batch.
-- The distance-history shift (previous_distance_to_fxe_nm = the row's OWN
-- pre-update distance_to_fxe_nm) happens inside this single statement —
-- deliberately not a client-side read-then-write.
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

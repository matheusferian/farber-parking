-- Live Aircraft Tracking — cadence/freshness correction.
--
-- Backend timing investigation (B.5 follow-up, C.2 design-checkpoint
-- finding) found a real architectural mismatch, proven against 69 real
-- production cron cycles (2026-08-29 15:38-16:46 UTC):
--
--   - cron fires every 60s with very tight jitter (median 59.9996s,
--     p95 60.10s, max observed 60.38s across 69 ticks) — the scheduler
--     itself is not the problem.
--   - claim_aircraft_refresh's cache TTL was also 60s, sitting on the
--     SAME boundary as the cron cadence. Whether a given tick's
--     `now() - last_success_at` cleared 60s came down to a few hundred
--     ms of accumulated latency each cycle — effectively a coin flip.
--     Losing that flip meant waiting a full extra cron tick, not a few
--     hundred ms, so healthy operation measured ~120s between actual
--     provider-calling cycles (34 real successes: median 119.996s, avg
--     119.995s) instead of the intended ~60s.
--   - aircraft_live_state_computed's LIVE cutoff was only 30s, far
--     shorter than the real ~120s (pre-fix) or even the corrected ~60s
--     (post-fix) refresh interval — physical_status would spend most of
--     its time collapsed to STALE even for a perfectly healthy,
--     actively-tracked aircraft.
--
-- This migration changes ONLY the two values below. Both object bodies
-- below are otherwise a verbatim copy of the live B.1 definitions —
-- function/view structure, lease duration, STALE/NO_SIGNAL cutoff (180s),
-- 3nm near-FXE radius, 0.5nm trend hysteresis, security_invoker, column
-- set/order — all unchanged. CREATE OR REPLACE preserves existing
-- grants automatically (the objects are not dropped), so no GRANT/REVOKE
-- statements are needed or included here. No Edge Function, cron, pg_net,
-- Vault, scheduler auth, or aircraft config change — the Edge Function
-- never passes p_cache_ttl_seconds explicitly, so it picks up the new
-- SQL-level default with zero code change on that side.
--
--   1. claim_aircraft_refresh: p_cache_ttl_seconds default 60 -> 45.
--      45s is comfortably below both the 60s cron cadence and the
--      worst observed cron jitter (60.38s) — >35x margin over the
--      actual jitter — so every normal cron tick reliably claims,
--      restoring the originally-intended ~1 provider batch/minute
--      instead of the accidental ~1/2min.
--   2. aircraft_live_state_computed: LIVE cutoff 30s -> 80s (both the
--      freshness case and the physical_status case use the same
--      cutoff — both instances changed together). With the TTL fix,
--      writes should land roughly every ~60.0-60.5s; 80s gives ~20s of
--      margin over that for normal provider/network latency variance,
--      so an actively-tracked aircraft should stay LIVE continuously
--      between healthy cycles instead of flickering to STALE every
--      other minute.
--
-- Safe to run more than once (CREATE OR REPLACE).

create or replace function public.claim_aircraft_refresh(
  p_worker_id text,
  p_lease_seconds integer default 20,
  p_cache_ttl_seconds integer default 45
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

create or replace view public.aircraft_live_state_computed
with (security_invoker = true)
as
select
  s.*,
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
  'Read-time computation of freshness/physical_status/distance_trend from the raw absolute timestamps in aircraft_live_state — never stored, so these labels can never go stale-themselves during a provider outage. LIVE cutoff corrected 30s -> 80s (2026-08-29, see 20260829_correct_aircraft_tracking_cadence_thresholds.sql) to match the actual ~60s provider refresh cadence after the paired claim_aircraft_refresh cache-TTL fix (60s -> 45s); STALE/NO_SIGNAL (180s), 3nm near-FXE radius, and 0.5nm trend hysteresis are unchanged from the original B.1 proposal.';

-- Rollback for 20260829_correct_aircraft_tracking_cadence_thresholds.sql
-- Restores the original B.1 values verbatim:
--   - claim_aircraft_refresh: p_cache_ttl_seconds default 45 -> 60
--   - aircraft_live_state_computed: LIVE cutoff 80s -> 30s
-- Everything else (lease duration, STALE/NO_SIGNAL 180s, 3nm/0.5nm,
-- security_invoker, column set, grants) is already unchanged and stays
-- that way. CREATE OR REPLACE preserves existing grants. Safe to run
-- more than once.

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

create or replace view public.aircraft_live_state_computed
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

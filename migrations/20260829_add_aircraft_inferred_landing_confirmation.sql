-- Live Aircraft Tracking — inferred landing confirmation.
--
-- Real production gap found via N624JR (2026-08-29): the aircraft's last
-- captured observation before signal loss was airborne (is_on_ground=false),
-- 0.85nm from FXE, 25ft AGL, descending at -704fpm — seconds from touchdown
-- by any reasonable reading — but the LITERAL landing rule
-- (is_on_ground=true AND distance_to_fxe_nm<=3, unchanged, still the
-- highest-confidence path) never fired, because no further ADS-B packet
-- ever arrived: the aircraft stopped transmitting at/near touchdown, which
-- is common for light GA aircraft at small fields. landed_at stayed NULL
-- indefinitely despite the aircraft having genuinely landed.
--
-- This migration adds a SECOND, lower-confidence, deliberately conservative
-- path: infer landing from (a) the last real observation matching a
-- final-approach profile and (b) a bounded period of subsequent silence,
-- rather than requiring a literal on-ground packet we may simply never
-- receive. It does NOT touch the literal path in upsert_aircraft_observations
-- at all — that migration/function is unchanged.
--
-- Candidate conditions (ALL required, on the CURRENTLY STORED row — nothing
-- here is written just to check it):
--   - landed_at IS NULL (not already confirmed by either path)
--   - is_on_ground = false (was airborne on the last observation)
--   - distance_to_fxe_nm <= 3 (same radius as the literal ON_GROUND_NEAR_FXE
--     rule — no new distance number introduced)
--   - altitude_ft <= 150 (real fixture: 25ft; 150ft is comfortably below a
--     normal ~270ft 3-degree-glideslope altitude at 0.85nm out, so it
--     excludes ordinary pattern/approach altitudes while giving margin
--     above the literal observed value)
--   - vertical_rate_fpm <= -200 (real fixture: -704fpm; clearly descending,
--     not level or climbing — separates a stabilized approach, typically
--     -300 to -700fpm, from a go-around climb-out, typically +500fpm+)
--   - silence >= 180s since last_position_at (reuses the EXISTING
--     STALE->NO_SIGNAL boundary rather than inventing a fourth timing
--     constant; spans 2-3 real ~60-120s poll cycles, ample time for a
--     go-around's climb to have been captured under healthy conditions)
--   - silence <= 60 minutes (an upper bound — real fixture sits at ~40min;
--     beyond this, a silent candidate is too ambiguous to confidently infer
--     from and is left for literal detection or manual handling instead)
--
-- Provider-health gate (fixes the exact failure mode this incident also
-- exposed: adsb.lol returned ZERO configured aircraft for 37 consecutive
-- minutes, a genuine provider-wide coverage gap, not 8 independent
-- landings):
--   - cardinality(p_returned_registrations) >= 1 — this cycle's OWN
--     successful provider response must have returned at least one
--     currently-configured aircraft (any of them, not necessarily the
--     candidate). If the provider returned nothing at all this cycle,
--     infer nothing — the silence is at least as plausibly explained by
--     a provider/coverage issue as by a landing.
--   - candidate registration must be in p_configured_registrations (never
--     an orphaned/historical row for a registration no longer configured).
--   - candidate registration must NOT be in p_returned_registrations — if
--     the candidate itself reappeared in THIS cycle's own batch (climbing,
--     increasing distance, or otherwise no longer matching), never infer
--     landing from its previously-stored state. Kept as explicit defense-
--     in-depth even though the Edge Function is designed to only call this
--     function from the worker whose OWN write for this cycle succeeded
--     (never a fenced-out worker), which already makes this exclusion
--     structurally redundant with write-ordering alone — cheap insurance
--     that doesn't depend on trusting that call-site discipline.
--
-- landed_at is set to last_position_at (the timestamp of the qualifying
-- observation itself), same field/semantics as the literal path — an
-- ESTIMATE, not an exact touchdown time. Worst-case timing error (a
-- candidate right at the 150ft/-200fpm boundary) is about 45 seconds;
-- typical error (matching the real fixture) is a few seconds. Since the TV
-- displays whole-minute precision ("N MIN AGO"), a bounded distance/speed
-- extrapolation was considered and rejected as unnecessary complexity for
-- an accuracy gain smaller than the display's own rounding.
--
-- Explicit NULL/empty-array handling: both arrays are coalesced to '{}'
-- before use, so a NULL argument behaves identically to an empty array
-- (fails safe — infers nothing) rather than relying on implicit
-- three-valued-logic NULL propagation in the WHERE clause.
--
-- No fencing/lease check needed on this function itself — it never calls
-- adsb.lol and operates purely on the table's current committed state plus
-- a per-call health signal; it is naturally idempotent (landed_at IS NULL
-- fails permanently once set) and safe to call from any context. The Edge
-- Function nonetheless only calls it from the single worker whose own
-- write for this cycle actually succeeded (see refresh-aircraft-state/index.ts),
-- for simpler reasoning, not because this function requires it.
--
-- Does NOT modify: the literal is_on_ground=true AND distance_to_fxe_nm<=3
-- path in upsert_aircraft_observations, aircraft_live_state_computed,
-- claim_aircraft_refresh, lease/fencing, cron, pg_net, Vault, scheduler
-- auth, or aircraft configuration.
--
-- Safe to run more than once (CREATE OR REPLACE).

create or replace function public.confirm_pending_aircraft_landings(
  p_configured_registrations text[],
  p_returned_registrations text[]
)
returns table (registration text)
language sql
set search_path = public
as $$
  update public.aircraft_live_state t
  set landed_at = t.last_position_at
  where cardinality(coalesce(p_returned_registrations, '{}'::text[])) >= 1
    and t.registration = any(coalesce(p_configured_registrations, '{}'::text[]))
    and not (t.registration = any(coalesce(p_returned_registrations, '{}'::text[])))
    and t.landed_at is null
    and t.is_on_ground = false
    and t.altitude_ft is not null and t.altitude_ft <= 150
    and t.vertical_rate_fpm is not null and t.vertical_rate_fpm <= -200
    and t.distance_to_fxe_nm is not null and t.distance_to_fxe_nm <= 3
    and t.last_position_at is not null
    and now() - t.last_position_at >= interval '180 seconds'
    and now() - t.last_position_at <= interval '60 minutes'
  returning t.registration;
$$;

comment on function public.confirm_pending_aircraft_landings(text[], text[]) is
  'Conservative inferred-landing confirmation — a SECOND, lower-confidence path alongside the literal is_on_ground=true AND distance_to_fxe_nm<=3 rule in upsert_aircraft_observations (unchanged). Infers landing from a stored final-approach profile (airborne, <=3nm, <=150ft, vertical_rate<=-200fpm) plus 180s-60min of subsequent silence, gated on THIS CYCLE''s own provider response having returned at least one configured aircraft (p_returned_registrations) — never infers anything during a cycle where the provider returned zero configured aircraft, which is exactly the real production gap this exists to close (see 2026-08-29 N624JR incident: 37 minutes of zero-aircraft provider responses). landed_at is set to last_position_at, an estimate documented as such. Fully generic — no registration-specific logic; p_configured_registrations/p_returned_registrations are supplied by the caller (the Edge Function''s own CONFIGURED_AIRCRAFT list and this cycle''s normalized observations) every time.';

-- Same default-grant correction as every other aircraft-tracking RPC in
-- this project (Postgres grants EXECUTE to PUBLIC by default on function
-- creation unless explicitly revoked) — this function mutates
-- aircraft_live_state and must only ever be callable by the service-role
-- Edge Function, never anon/authenticated.
revoke all on function public.confirm_pending_aircraft_landings(text[], text[]) from public, anon, authenticated;
grant execute on function public.confirm_pending_aircraft_landings(text[], text[]) to service_role;

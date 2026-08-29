// Live Aircraft Tracking — Phase B.2. Manually invokable only (no cron,
// no pg_net, no Vault scheduling yet — see PROJECT.md, Live Aircraft
// Tracking). This is the ONLY code in the project authorized to call
// adsb.lol; TV Mode never will (it only ever reads
// aircraft_live_state_computed, see the B.1 migration).
//
// Flow: claim lease -> (only if claimed) one batch provider request ->
// normalize -> dedupe by configured registration -> upsert -> complete.
// There is no code path that reaches the provider fetch without first
// successfully claiming the lease.

import { createClient } from 'npm:@supabase/supabase-js@2';

// ── STATIC AIRCRAFT CONFIG ───────────────────────────────────────────
// The 8 Makers Air Caravans. `registration` here is the ONLY authoritative
// source written to aircraft_live_state.registration — the provider's own
// `ac.r` field is read nowhere in this file. Provider aircraft whose hex
// isn't in this list are ignored entirely, never written.
export const CONFIGURED_AIRCRAFT: ReadonlyArray<{ icaoHex: string; registration: string }> = [
  { icaoHex: 'A1B08B', registration: 'N208JH' },
  { icaoHex: 'A9F415', registration: 'N740RV' },
  { icaoHex: 'AB34E1', registration: 'N821DD' },
  { icaoHex: 'A3470B', registration: 'N310CH' },
  { icaoHex: 'A0BAFA', registration: 'N146WM' },
  { icaoHex: 'A66930', registration: 'N512DH' },
  { icaoHex: 'A848E9', registration: 'N633AH' },
  { icaoHex: 'A825F1', registration: 'N624JR' },
];

export function normalizeHex(hex: string): string {
  return String(hex ?? '').trim().toUpperCase();
}

const AIRCRAFT_BY_HEX = new Map<string, string>(
  CONFIGURED_AIRCRAFT.map((a) => [normalizeHex(a.icaoHex), a.registration]),
);

// KFXE — Fort Lauderdale Executive Airport. Validated against OurAirports
// during Fase 1 investigation (see PROJECT.md, Live Aircraft Tracking).
// Centralized here — nowhere else in this function hardcodes a coordinate.
const FXE_LAT = 26.1972999573;
const FXE_LON = -80.1707000732;

const PROVIDER_BASE_URL = 'https://api.adsb.lol/v2/icao/';
// Matches adsb.lol's own internal backend timeout (see re-api.py, aiohttp
// ClientTimeout total=5.0, found during Fase 2 investigation) — no point
// waiting longer than the provider itself is willing to.
const PROVIDER_TIMEOUT_MS = 5000;

export function isFiniteNumber(v: unknown): v is number {
  return typeof v === 'number' && Number.isFinite(v);
}

// A merely-finite number is not enough for body.now: 0, epoch-seconds
// instead of epoch-ms (off by a factor of 1000), or a wildly future/past
// value would all pass Number.isFinite() and still produce a technically
// valid JS Date that silently corrupts every freshness calculation
// downstream. Require it to be within a documented tolerance of the
// receipt time captured locally right before this check runs.
//
// 5 minutes is generous enough to absorb real clock drift between our
// Edge Function host and adsb.lol's servers (not measured — no clock-sync
// data exists yet), while remaining far tighter than the ~1000x error an
// epoch-seconds mixup would produce, so that specific failure mode is
// caught reliably rather than by coincidence.
export const CLOCK_SKEW_TOLERANCE_MS = 5 * 60 * 1000;

export function isPlausibleEpochMs(
  candidate: unknown,
  receiptTimeMs: number,
  toleranceMs: number,
): candidate is number {
  if (!isFiniteNumber(candidate)) return false;
  if (candidate <= 0) return false;
  return Math.abs(candidate - receiptTimeMs) <= toleranceMs;
}

// seen/seen_pos are "elapsed seconds" — must be finite and non-negative.
// Combined with isPlausibleEpochMs() gating batchTimeMs itself, this
// structurally guarantees last_message_at/last_position_at (=
// batchTimeMs - elapsed*1000) can never land after batchTimeMs, so never
// silently produces a future timestamp.
export function isValidElapsedSeconds(v: unknown): v is number {
  return isFiniteNumber(v) && v >= 0;
}

// ── GEO — Haversine, no dependency ───────────────────────────────────
export function haversineDistanceNm(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const earthRadiusNm = 3440.065;
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * earthRadiusNm * Math.asin(Math.sqrt(a));
}

// ── PROVIDER RESPONSE SHAPE ───────────────────────────────────────────
export interface ProviderBody {
  ac: unknown[];
  now: unknown;
}

export function isValidProviderBody(body: unknown): body is ProviderBody {
  return typeof body === 'object' && body !== null && Array.isArray((body as { ac?: unknown }).ac);
}

export interface NormalizedObservation {
  registration: string;
  icao_hex: string;
  callsign: string | null;
  latitude: number | null;
  longitude: number | null;
  altitude_ft: number | null;
  is_on_ground: boolean;
  ground_speed_kt: number | null;
  track_deg: number | null;
  vertical_rate_fpm: number | null;
  distance_to_fxe_nm: number | null;
  last_message_at: string | null;
  last_position_at: string | null;
  provider: string;
  polled_at: string;
}

// ── NORMALIZATION — match by hex, assign registration from config,
// dedupe by registration ───────────────────────────────────────────
export function normalizeObservations(
  rawAircraft: unknown[],
  batchTimeMs: number,
  polledAtIso: string,
): NormalizedObservation[] {
  const byRegistration = new Map<string, NormalizedObservation>();

  for (const raw of rawAircraft) {
    if (typeof raw !== 'object' || raw === null) continue;
    const ac = raw as Record<string, unknown>;

    const hex = normalizeHex(String(ac.hex ?? ''));
    const registration = AIRCRAFT_BY_HEX.get(hex);
    if (!registration) continue; // unconfigured aircraft — ignored entirely, never ac.r

    const isOnGround = ac.alt_baro === 'ground';
    const altitudeFt = !isOnGround && isFiniteNumber(ac.alt_baro) ? ac.alt_baro : null;
    const latitude = isFiniteNumber(ac.lat) ? ac.lat : null;
    const longitude = isFiniteNumber(ac.lon) ? ac.lon : null;

    const lastMessageAt = isValidElapsedSeconds(ac.seen)
      ? new Date(batchTimeMs - ac.seen * 1000).toISOString()
      : null;
    const lastPositionAt = isValidElapsedSeconds(ac.seen_pos)
      ? new Date(batchTimeMs - ac.seen_pos * 1000).toISOString()
      : null;

    const distanceToFxeNm =
      latitude !== null && longitude !== null
        ? haversineDistanceNm(latitude, longitude, FXE_LAT, FXE_LON)
        : null;

    // Dedup by configured registration: a malformed/duplicate provider
    // payload for the same aircraft must never reach
    // upsert_aircraft_observations() twice, which would make Postgres's
    // ON CONFLICT DO UPDATE fail ("command cannot affect row a second
    // time"). Last occurrence wins — a legitimate provider response never
    // has two distinct entries for the same real aircraft, so this only
    // ever guards against malformed input, not a real data-quality choice.
    byRegistration.set(registration, {
      registration,
      icao_hex: hex,
      callsign: typeof ac.flight === 'string' ? ac.flight.trim() || null : null,
      latitude,
      longitude,
      altitude_ft: altitudeFt,
      is_on_ground: isOnGround,
      ground_speed_kt: isFiniteNumber(ac.gs) ? ac.gs : null,
      track_deg: isFiniteNumber(ac.track) ? ac.track : null,
      vertical_rate_fpm: isFiniteNumber(ac.baro_rate) ? ac.baro_rate : null,
      distance_to_fxe_nm: distanceToFxeNm,
      last_message_at: lastMessageAt,
      last_position_at: lastPositionAt,
      provider: 'adsb.lol',
      polled_at: polledAtIso,
    });
  }

  return Array.from(byRegistration.values());
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

export async function handleRequest(_req: Request): Promise<Response> {
  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceRoleKey) {
    // Never log the key itself — only that it's missing.
    return jsonResponse({ refreshed: false, reason: 'MISSING_SERVICE_ROLE_CONFIG' }, 500);
  }

  const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });

  const workerId = `edge-${crypto.randomUUID()}`;

  // ── Lease is mandatory before any provider call ───────────────────
  const { data: claimRows, error: claimError } = await supabaseAdmin.rpc('claim_aircraft_refresh', {
    p_worker_id: workerId,
  });

  if (claimError) {
    return jsonResponse({ refreshed: false, reason: 'CLAIM_RPC_ERROR', message: claimError.message }, 500);
  }

  const claim = claimRows?.[0] as
    | { claimed: boolean; cache_is_fresh: boolean; last_success_at: string | null }
    | undefined;

  if (!claim?.claimed) {
    // Lease held by another worker, or cache still fresh — either way,
    // adsb.lol is never touched on this path. providerFetchAttempted is
    // hardcoded false here and can only ever become true past the fetch()
    // call below — there is no code path that sets it true without that
    // line actually having executed, which is the concrete evidence this
    // field exists to provide (see PROJECT.md, Live Aircraft Tracking).
    return jsonResponse({
      refreshed: false,
      reason: 'NOT_CLAIMED',
      cachePreserved: true,
      cacheIsFresh: !!claim?.cache_is_fresh,
      lastSuccessAt: claim?.last_success_at ?? null,
      providerFetchAttempted: false,
    });
  }

  // Set true immediately before the only fetch() call to adsb.lol in this
  // codebase, which only ever executes inside the `claim.claimed` branch.
  // Declared here (not `const` inside the try) so the catch block below
  // can still report an accurate true if fetch() itself throws (timeout,
  // network error) — an attempt was made either way.
  let providerFetchAttempted = false;

  // ── Claimed: exactly one batch request for all configured aircraft ─
  try {
    const hexList = CONFIGURED_AIRCRAFT.map((a) => a.icaoHex).join(',');
    const providerUrl = PROVIDER_BASE_URL + hexList;

    providerFetchAttempted = true;
    const res = await fetch(providerUrl, { signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS) });

    if (res.status !== 200) {
      await supabaseAdmin.rpc('complete_aircraft_refresh', {
        p_worker_id: workerId,
        p_success: false,
        p_provider_status: res.status,
        p_error: `provider_http_${res.status}`,
      });
      return jsonResponse({
        refreshed: false,
        reason: 'PROVIDER_HTTP_ERROR',
        providerStatus: res.status,
        cachePreserved: true,
        providerFetchAttempted,
      });
    }

    const body = await res.json().catch(() => null);
    if (!isValidProviderBody(body)) {
      await supabaseAdmin.rpc('complete_aircraft_refresh', {
        p_worker_id: workerId,
        p_success: false,
        p_provider_status: res.status,
        p_error: 'malformed_response',
      });
      return jsonResponse({ refreshed: false, reason: 'MALFORMED_RESPONSE', cachePreserved: true, providerFetchAttempted });
    }

    // Single batch reference timestamp, provider-supplied — derive every
    // aircraft's absolute timestamps from this one value, never our own
    // clock called per-aircraft. A merely-finite body.now is not enough
    // (see isPlausibleEpochMs doc comment) — it must be within a
    // documented clock-skew tolerance of our own receipt time.
    const receiptTimeMs = Date.now();
    const batchTimeMs = body.now;
    if (!isPlausibleEpochMs(batchTimeMs, receiptTimeMs, CLOCK_SKEW_TOLERANCE_MS)) {
      await supabaseAdmin.rpc('complete_aircraft_refresh', {
        p_worker_id: workerId,
        p_success: false,
        p_provider_status: res.status,
        p_error: 'invalid_provider_timestamp',
      });
      return jsonResponse({ refreshed: false, reason: 'INVALID_PROVIDER_TIMESTAMP', cachePreserved: true, providerFetchAttempted });
    }

    const polledAtIso = new Date().toISOString(); // one receipt timestamp for the whole batch

    const observations = normalizeObservations(body.ac, batchTimeMs, polledAtIso);

    // Empty valid batch (HTTP 200, ac: []) is still a provider success —
    // the upsert call is simply skippable when there's nothing to write.
    if (observations.length > 0) {
      // p_worker_id is checked INSIDE this RPC, in the same INSERT
      // statement as the write itself (lease fencing — see the B.2
      // hardening migration). We always pass a non-empty array here, so
      // rowCount === 0 is unambiguous proof this worker was fenced out
      // (lease expired or reclaimed) between claiming and writing.
      const { data: rowCount, error: upsertError } = await supabaseAdmin.rpc('upsert_aircraft_observations', {
        p_worker_id: workerId,
        p_observations: observations,
      });
      if (upsertError) {
        await supabaseAdmin.rpc('complete_aircraft_refresh', {
          p_worker_id: workerId,
          p_success: false,
          p_provider_status: res.status,
          p_error: `upsert_failed: ${upsertError.message}`,
        });
        return jsonResponse({ refreshed: false, reason: 'UPSERT_FAILED', cachePreserved: true, providerFetchAttempted });
      }
      if (rowCount === 0) {
        // Fenced out: lease expired or was reclaimed by a newer worker
        // between claim and write. complete_aircraft_refresh is still
        // attempted defensively, but its own lock_owner guard means it
        // will just as safely no-op if this worker no longer owns the
        // lease — no double-reporting risk either way.
        await supabaseAdmin.rpc('complete_aircraft_refresh', {
          p_worker_id: workerId,
          p_success: false,
          p_provider_status: res.status,
          p_error: 'lease_fenced_out_before_write',
        });
        return jsonResponse({ refreshed: false, reason: 'LEASE_FENCED_OUT', cachePreserved: true, providerFetchAttempted });
      }
    }

    await supabaseAdmin.rpc('complete_aircraft_refresh', {
      p_worker_id: workerId,
      p_success: true,
      p_provider_status: res.status,
      p_error: null,
    });

    return jsonResponse({
      refreshed: true,
      provider: 'adsb.lol',
      providerRequests: 1,
      providerStatus: res.status,
      totalConfigured: CONFIGURED_AIRCRAFT.length,
      totalReturnedByProvider: body.ac.length,
      totalMatchedAndWritten: observations.length,
      registrationsWritten: observations.map((o) => o.registration),
      providerFetchAttempted,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    await supabaseAdmin.rpc('complete_aircraft_refresh', {
      p_worker_id: workerId,
      p_success: false,
      p_provider_status: null,
      p_error: message.slice(0, 500),
    });
    return jsonResponse({ refreshed: false, reason: 'EXCEPTION', message, cachePreserved: true, providerFetchAttempted });
  }
}

// Only starts the HTTP listener when this file is the entrypoint (which is
// exactly how the Supabase Edge Runtime invokes it in production) — never
// when imported by another module, e.g. for isolated testing of the pure
// functions above.
if (import.meta.main) {
  Deno.serve(handleRequest);
}

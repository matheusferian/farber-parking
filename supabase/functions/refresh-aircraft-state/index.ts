// Live Aircraft Tracking — Phase B.2/B.3/B.4. Scheduled once per minute
// by pg_cron + pg_net (B.4 migration) and still manually invokable for
// diagnostics. This is the ONLY code in the project authorized to call
// adsb.lol; TV Mode never will (it only ever reads
// aircraft_live_state_computed, see the B.1 migration).
//
// Flow: authenticate scheduler -> claim lease -> (only if claimed) one
// batch provider request -> evaluate/normalize -> dedupe by configured
// registration -> upsert -> complete. There is no code path that reaches
// the provider fetch without first passing scheduler authentication AND
// successfully claiming the lease, and no code path that mutates
// aircraft_live_state without the lease still being valid at write time
// (see the B.2 fencing migration).
//
// B.4 scheduler authentication: Supabase's platform-level JWT
// verification stays enabled, but it only proves the caller holds SOME
// valid project JWT — the anon key it accepts is already public in the
// frontend, so it cannot alone prove the caller is our own cron
// scheduler. The X-Aircraft-Refresh-Secret header (checked via
// timingSafeEqual against AIRCRAFT_REFRESH_SCHEDULER_SECRET, a dedicated
// high-entropy value that is neither the anon key nor the service_role
// key) is the actual authorization boundary — checked first, before the
// Supabase client is even created, before any lease claim or provider
// fetch. Unauthorized requests get providerFetchAttempted:false and a
// 401, same evidentiary guarantee as the lease's own NOT_CLAIMED path.
//
// B.3 hardening: every provider/runtime failure mode (timeout, non-200,
// malformed body, invalid timestamp, claim/upsert RPC errors) never
// mutates aircraft_live_state, never touches last_success_at, and always
// attempts (once, never retried) to record the failure via
// complete_aircraft_refresh. See classifyFetchError()/safeComplete()/
// evaluateProviderResponse() below.
//
// One deliberate exception to "failure never mutates aircraft_live_state"
// — NOT a failure mode, a genuine partial-success case: the observation
// upsert and the final complete_aircraft_refresh(success:true) call are
// TWO SEPARATE database transactions. If the upsert commits but the
// completion call that follows it fails, the aircraft rows are already
// correctly written and stay written — there is nothing to roll back,
// and this code does not fabricate doing so. That response is reported
// as `refreshed:false, reason:'COMPLETION_FAILED_AFTER_WRITE',
// dataPlaneWritten:true` — never `refreshed:true` (control-plane
// telemetry did not confirm), but also never claiming nothing was
// written when it was. last_success_at is left at its previous (stale)
// value in that case; the lease still expires on its own original
// schedule regardless, so the next refresh attempt is always safe. See
// the COMPLETION_FAILED_AFTER_WRITE branch below for the full reasoning,
// and PROJECT.md, Live Aircraft Tracking, for why this stays a
// two-transaction design for now rather than one atomic RPC.
//
// Telemetry field semantics (aircraft_refresh_control):
//   last_attempt_at    — advances on every successful lease CLAIM (set by
//                         claim_aircraft_refresh itself, B.1), regardless
//                         of what happens afterward.
//   last_success_at    — advances ONLY when complete_aircraft_refresh
//                         (success:true) itself is successfully recorded.
//                         Per the exception above, this means a successful
//                         data-plane write can transiently coexist with an
//                         older last_success_at if only the completion
//                         call failed — that must be read as a
//                         control-plane telemetry gap, not as evidence
//                         the aircraft rows are stale or unwritten.
//   last_provider_status / last_error / consecutive_failures — written by
//                         complete_aircraft_refresh; reset to
//                         null/null/0 on success, incremented/populated
//                         on failure (B.1).

import { createClient } from 'npm:@supabase/supabase-js@2';

// Minimal surface actually used from the Supabase client — only `.rpc()`.
// Declaring our own interface (rather than importing the full
// SupabaseClient type) lets tests inject a lightweight fake without
// needing to satisfy the entire real client's shape.
export interface RpcClient {
  rpc(
    fn: string,
    params: object,
  ): PromiseLike<{ data: unknown; error: { message: string } | null }>;
}

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

// ── SCHEDULER AUTHENTICATION (B.4 hardening) ─────────────────────────
// Supabase JWT verification (platform-level, stays enabled) only proves
// the caller holds SOME valid project JWT — the anon key is public in
// the frontend, so it cannot by itself prove the caller is our own
// cron scheduler. This header is the actual authorization boundary: a
// dedicated, high-entropy secret that is neither the anon key nor the
// service_role key, known only to (a) the Vault entry pg_net reads to
// send it, and (b) this function's own AIRCRAFT_REFRESH_SCHEDULER_SECRET
// env var. Checked before any lease claim or provider fetch — there is
// no code path that reaches claim_aircraft_refresh without this passing
// first.
export const SCHEDULER_SECRET_HEADER = 'X-Aircraft-Refresh-Secret';

// Constant-time-ish comparison to reduce timing side-channel exposure
// for a 64-hex-char secret — not cryptographically perfect (JS string
// operations aren't guaranteed constant-time at the engine level), but
// meaningfully better than a naive `===` short-circuit, and proportionate
// to this system's actual threat model (a low-value internal trigger
// endpoint, not a high-security auth boundary).
export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

// ── ERROR CLASSIFICATION ──────────────────────────────────────────────
// Concise, sanitized labels for last_error. We never send credentials to
// the provider (the request is an unauthenticated public GET, no
// Authorization header), so err.message can't contain them by
// construction — this is trimmed short regardless, per the "concise
// sanitized" requirement, and specifically distinguishes a timeout from
// other network failures for clearer telemetry.
export function classifyFetchError(err: unknown): string {
  if (err instanceof Error) {
    if (err.name === 'TimeoutError' || err.name === 'AbortError') return 'provider_timeout';
    return `network_error: ${err.message}`.slice(0, 200);
  }
  return `network_error: ${String(err)}`.slice(0, 200);
}

// ── PROVIDER RESPONSE EVALUATION — pure/testable, no network access ───
// Takes an already-fetched Response (real fetch() result in production,
// a synthetic `new Response(...)` in tests) so every HTTP-status/body
// failure mode is fully testable without hitting adsb.lol.
export type ProviderEvaluation =
  | {
      ok: true;
      observations: NormalizedObservation[];
      totalReturnedByProvider: number;
      providerStatus: number;
    }
  | { ok: false; reason: string; providerStatus: number | null };

export async function evaluateProviderResponse(
  res: Response,
  receiptTimeMs: number,
): Promise<ProviderEvaluation> {
  // Item 2: 429, 5xx, and every other non-200 status share one path —
  // no upsert, no change to last_success_at, provider status preserved
  // for telemetry. lock_until is never touched here or anywhere in this
  // file for rate-limit/backoff purposes — it means lease/concurrency
  // only (see B.1/B.2 migrations).
  if (res.status !== 200) {
    return { ok: false, reason: 'PROVIDER_HTTP_ERROR', providerStatus: res.status };
  }

  // Item 4: a JSON parse exception (including genuinely non-JSON bodies)
  // is a failure, not a crash — caught here, never touches aircraft rows.
  let body: unknown;
  try {
    body = await res.json();
  } catch {
    return { ok: false, reason: 'MALFORMED_RESPONSE', providerStatus: res.status };
  }

  // Item 3: HTTP 200 is only treated as success when the body is a valid
  // object AND `ac` is an array AND `now` is a plausible timestamp — a
  // malformed 200 (missing ac, ac not an array, garbage now) is a
  // failure, never treated as a valid empty batch. A genuinely valid
  // `ac: []` still passes this check and is a real success (item 10).
  if (!isValidProviderBody(body)) {
    return { ok: false, reason: 'MALFORMED_RESPONSE', providerStatus: res.status };
  }

  if (!isPlausibleEpochMs(body.now, receiptTimeMs, CLOCK_SKEW_TOLERANCE_MS)) {
    return { ok: false, reason: 'INVALID_PROVIDER_TIMESTAMP', providerStatus: res.status };
  }

  const polledAtIso = new Date(receiptTimeMs).toISOString(); // one receipt timestamp for the whole batch
  const observations = normalizeObservations(body.ac, body.now, polledAtIso);

  return {
    ok: true,
    observations,
    totalReturnedByProvider: body.ac.length,
    providerStatus: res.status,
  };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

interface CompleteParams {
  p_worker_id: string;
  p_success: boolean;
  p_provider_status: number | null;
  p_error: string | null;
}

// Item 5: complete_aircraft_refresh itself can fail (network blip to the
// database, transient Postgres error). This is called exactly once per
// refresh attempt — never retried recursively or in a loop — and never
// throws; it reports back whether the completion actually landed so the
// HTTP response can honestly reflect it via `completionRecorded` (item 8)
// instead of silently assuming success. Logging is best-effort only and
// never includes request/auth headers or the service-role key.
export async function safeComplete(
  supabaseAdmin: RpcClient,
  params: CompleteParams,
): Promise<boolean> {
  const { error } = await supabaseAdmin.rpc('complete_aircraft_refresh', params);
  if (error) {
    console.error(
      JSON.stringify({
        event: 'complete_aircraft_refresh_failed',
        workerId: params.p_worker_id,
        message: error.message,
      }),
    );
    return false;
  }
  return true;
}

export interface HandleRequestDeps {
  // Injectable for deterministic handler-level tests — no real network or
  // database access required. Defaults to the real Supabase client, the
  // global fetch, and Deno.env when omitted, which is exactly how
  // production (and Deno.serve below) invokes this function.
  rpcClient: RpcClient;
  fetchImpl: typeof fetch;
  expectedSchedulerSecret: string | undefined;
}

export async function handleRequest(req: Request, deps?: Partial<HandleRequestDeps>): Promise<Response> {
  // ── Scheduler authentication — checked before ANYTHING else, including
  // creating the Supabase client. No claim, no fetch, no DB access of any
  // kind happens before this passes. See SCHEDULER_SECRET_HEADER's doc
  // comment for why this exists alongside (not instead of) the platform
  // JWT gate.
  const expectedSchedulerSecret =
    deps && 'expectedSchedulerSecret' in deps ? deps.expectedSchedulerSecret : Deno.env.get('AIRCRAFT_REFRESH_SCHEDULER_SECRET');

  if (!expectedSchedulerSecret) {
    // Server misconfiguration — the secret was never provisioned. Never
    // silently fall through to allowing requests without it.
    return jsonResponse(
      {
        refreshed: false,
        reason: 'SCHEDULER_SECRET_NOT_CONFIGURED',
        providerFetchAttempted: false,
        cachePreserved: true,
        completionRecorded: false,
      },
      500,
    );
  }

  const providedSchedulerSecret = req.headers.get(SCHEDULER_SECRET_HEADER);
  if (!providedSchedulerSecret || !timingSafeEqual(providedSchedulerSecret, expectedSchedulerSecret)) {
    // Never log the provided or expected value — only that the check failed.
    return jsonResponse(
      {
        refreshed: false,
        reason: 'UNAUTHORIZED',
        providerFetchAttempted: false,
        cachePreserved: true,
        completionRecorded: false,
      },
      401,
    );
  }

  let supabaseAdmin: RpcClient;
  if (deps?.rpcClient) {
    // Test path: never touches Deno.env at all when a client is injected.
    supabaseAdmin = deps.rpcClient;
  } else {
    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!supabaseUrl || !serviceRoleKey) {
      // Never log the key itself — only that it's missing.
      return jsonResponse(
        {
          refreshed: false,
          reason: 'MISSING_SERVICE_ROLE_CONFIG',
          providerFetchAttempted: false,
          cachePreserved: true,
          completionRecorded: false,
        },
        500,
      );
    }
    supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
  }
  const fetchImpl = deps?.fetchImpl ?? fetch;

  const workerId = `edge-${crypto.randomUUID()}`;

  // ── Lease is mandatory before any provider call ───────────────────
  const { data: claimRows, error: claimError } = await supabaseAdmin.rpc('claim_aircraft_refresh', {
    p_worker_id: workerId,
  });

  if (claimError) {
    // Nothing was claimed — nothing to complete/release.
    return jsonResponse(
      {
        refreshed: false,
        reason: 'CLAIM_RPC_ERROR',
        message: claimError.message,
        providerFetchAttempted: false,
        cachePreserved: true,
        completionRecorded: false,
      },
      500,
    );
  }

  const claim = (claimRows as Array<{ claimed: boolean; cache_is_fresh: boolean; last_success_at: string | null }> | null)
    ?.[0];

  if (!claim?.claimed) {
    // Lease held by another worker, or cache still fresh — either way,
    // adsb.lol is never touched on this path. providerFetchAttempted is
    // hardcoded false here and can only ever become true past the fetch()
    // call below — there is no code path that sets it true without that
    // line actually having executed, which is the concrete evidence this
    // field exists to provide (see PROJECT.md, Live Aircraft Tracking).
    // completionRecorded is false because nothing was claimed, so there
    // is nothing to complete.
    return jsonResponse({
      refreshed: false,
      reason: 'NOT_CLAIMED',
      cachePreserved: true,
      cacheIsFresh: !!claim?.cache_is_fresh,
      lastSuccessAt: claim?.last_success_at ?? null,
      providerFetchAttempted: false,
      completionRecorded: false,
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
    const res = await fetchImpl(providerUrl, { signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS) });
    const receiptTimeMs = Date.now();

    const evaluation = await evaluateProviderResponse(res, receiptTimeMs);

    if (!evaluation.ok) {
      const completionRecorded = await safeComplete(supabaseAdmin, {
        p_worker_id: workerId,
        p_success: false,
        p_provider_status: evaluation.providerStatus,
        p_error: evaluation.reason.toLowerCase(),
      });
      return jsonResponse({
        refreshed: false,
        reason: evaluation.reason,
        providerStatus: evaluation.providerStatus,
        cachePreserved: true,
        providerFetchAttempted,
        completionRecorded,
      });
    }

    const { observations, totalReturnedByProvider, providerStatus } = evaluation;

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
        const completionRecorded = await safeComplete(supabaseAdmin, {
          p_worker_id: workerId,
          p_success: false,
          p_provider_status: providerStatus,
          p_error: `upsert_failed: ${upsertError.message}`.slice(0, 200),
        });
        return jsonResponse({
          refreshed: false,
          reason: 'UPSERT_FAILED',
          cachePreserved: true,
          providerFetchAttempted,
          completionRecorded,
        });
      }
      if (rowCount === 0) {
        // Fenced out: lease expired or was reclaimed by a newer worker
        // between claim and write. complete_aircraft_refresh is still
        // attempted defensively, but its own lock_owner guard means it
        // will just as safely no-op if this worker no longer owns the
        // lease — no double-reporting risk either way.
        const completionRecorded = await safeComplete(supabaseAdmin, {
          p_worker_id: workerId,
          p_success: false,
          p_provider_status: providerStatus,
          p_error: 'lease_fenced_out_before_write',
        });
        return jsonResponse({
          refreshed: false,
          reason: 'LEASE_FENCED_OUT',
          cachePreserved: true,
          providerFetchAttempted,
          completionRecorded,
        });
      }
    }

    // Data-plane mutation (if any) has already committed in its own
    // separate transaction by this point (the upsert RPC call above, if
    // observations.length > 0). This completion call is a SEPARATE
    // transaction — it can fail independently of that write having
    // already succeeded.
    const completionRecorded = await safeComplete(supabaseAdmin, {
      p_worker_id: workerId,
      p_success: true,
      p_provider_status: providerStatus,
      p_error: null,
    });

    if (!completionRecorded) {
      // Real, rare gap: the write already committed, but the closing
      // complete_aircraft_refresh(success:true) call itself failed. Per
      // explicit design decision, we do NOT report refreshed:true here —
      // control-plane telemetry did not confirm — and we do NOT attempt
      // to roll back or fabricate undoing a write that has already
      // committed and cannot actually be reversed from this point.
      // `dataPlaneWritten` tells the caller the aircraft rows genuinely
      // are fresh despite refreshed:false, so this isn't confused with
      // any other failure mode where nothing was written at all.
      //
      // last_success_at is left at its PREVIOUS value (stale) and the
      // lease is not released here, but lock_until is unaffected by this
      // failure and still expires on its own original schedule — the
      // next refresh attempt is safe once that passes, with no retry
      // loop needed (see PROJECT.md, Live Aircraft Tracking, for the
      // architecture note on why this stays a two-transaction design
      // for now rather than one atomic RPC).
      return jsonResponse({
        refreshed: false,
        reason: 'COMPLETION_FAILED_AFTER_WRITE',
        dataPlaneWritten: observations.length > 0,
        totalMatchedAndWritten: observations.length,
        registrationsWritten: observations.map((o) => o.registration),
        providerStatus,
        providerFetchAttempted,
        completionRecorded: false,
      });
    }

    return jsonResponse({
      refreshed: true,
      provider: 'adsb.lol',
      providerRequests: 1,
      providerStatus,
      totalConfigured: CONFIGURED_AIRCRAFT.length,
      totalReturnedByProvider,
      totalMatchedAndWritten: observations.length,
      registrationsWritten: observations.map((o) => o.registration),
      providerFetchAttempted,
      completionRecorded: true,
    });
  } catch (err) {
    // Covers fetch() throwing outright: timeout (AbortSignal), DNS/TCP/TLS
    // failure, etc. — never touches aircraft_live_state, cache preserved.
    const sanitized = classifyFetchError(err);
    const completionRecorded = await safeComplete(supabaseAdmin, {
      p_worker_id: workerId,
      p_success: false,
      p_provider_status: null,
      p_error: sanitized,
    });
    return jsonResponse({
      refreshed: false,
      reason: 'EXCEPTION',
      message: sanitized,
      cachePreserved: true,
      providerFetchAttempted,
      completionRecorded,
    });
  }
}

// Only starts the HTTP listener when this file is the entrypoint (which is
// exactly how the Supabase Edge Runtime invokes it in production) — never
// when imported by another module, e.g. for isolated testing of the pure
// functions above.
if (import.meta.main) {
  Deno.serve((req) => handleRequest(req));
}

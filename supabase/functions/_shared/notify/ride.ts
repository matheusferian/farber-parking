// Jet Runway ride READY → push to the staff devices that enabled alerts (same targets as guest
// messages). Claimed once per ride (airvalet_notify_log), so a repeated READY never pushes twice.
// Never sends anything to guests; never throws.

import { sendPush } from '../push/webpush.ts';
import type { Vapid } from './notify.ts';

// deno-lint-ignore no-explicit-any
type Db = { rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: any; error: any }> };

export function ridePushPayload(last4: string) {
  return { title: 'JET RUNWAY · READY', body: `…${last4} is ready for the ride back`, url: '/#rides', tag: 'airvalet-ride' };
}

export async function notifyRideReady(db: Db, vapid: Vapid | null, rideId: string, last4: string,
  log: (event: string, data: Record<string, unknown>) => void = () => {}, pushImpl: typeof sendPush = sendPush): Promise<number> {
  if (!vapid) return 0;
  try {
    const key = `push:RIDE_READY:${rideId}`;
    const { data: claimed } = await db.rpc('airvalet_notify_claim', { p_dedupe_key: key, p_channel: 'push' });
    if (!claimed) return 0;
    const { data: targets } = await db.rpc('airvalet_push_targets', {});
    let ok = 0;
    for (const t of (targets ?? []) as { id: string; endpoint: string; p256dh: string; auth: string }[]) {
      try {
        const r = await pushImpl(t, ridePushPayload(last4), vapid);
        await db.rpc('airvalet_push_result', { p_id: t.id, p_ok: r.ok, p_gone: r.gone });
        if (r.ok) ok += 1;
      } catch (e) { log('ride.push_device_error', { error: (e as Error)?.name || 'Error' }); }
    }
    await db.rpc('airvalet_notify_finish', { p_dedupe_key: key, p_status: ok ? 'sent' : 'skipped', p_segments: null, p_sid: null, p_detail: `${ok} device(s)` });
    return ok;
  } catch (e) {
    log('ride.push_error', { error: (e as Error)?.name || 'Error' });
    return 0;
  }
}

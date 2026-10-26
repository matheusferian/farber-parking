// Staff push alerts on the phones that asked for them (airvalet_push_subs):
//   CHECK_IN  new check-in          (ADMIN phones)
//   TIP       Stripe tip received   (ADMIN phones)
// Called by the staff-alert Edge Function, which the database triggers for the
// new row. One claim per event (airvalet_staff_alert_claim); check-in bursts
// become one "more check-ins" alert. Never sends anything to passengers; a
// failure never affects the check-in or the payment.

import { sendPush, type PushResult } from '../push/webpush.ts';
import type { Vapid } from './notify.ts';

// deno-lint-ignore no-explicit-any
type Db = { rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: any; error: any }> };

export type StaffKind = 'CHECK_IN' | 'TIP';
export type StaffClaim = {
  mode: 'single' | 'summary' | 'skip'; key?: string;
  name?: string | null; ticket?: string | null; loc?: string | null; amount_cents?: number | null;
};
export type StaffDeps = { db: Db; vapid: Vapid | null; pushImpl?: typeof sendPush; log?: (event: string, data: Record<string, unknown>) => void };
export type StaffResult = { kind: string; mode: string; push: number };

export const STAFF_KINDS: readonly StaffKind[] = ['CHECK_IN', 'TIP'];

function money(cents: number | null | undefined): string {
  const c = Number.isFinite(Number(cents)) ? Math.max(0, Math.round(Number(cents))) : 0;
  return '$' + (c / 100).toFixed(2);
}

// What the phone shows. Without "show details" only the ticket / amount, never the guest name.
export function staffPushPayload(kind: StaffKind, c: StaffClaim, showPreview: boolean): { title: string; body: string; url: string; tag: string } {
  const ticket = c.ticket ? `Ticket #${c.ticket}` : '';
  if (kind === 'TIP') {
    const who = showPreview && c.name ? `${String(c.name).slice(0, 40)}${ticket ? ' · ' + ticket : ''}` : (ticket || 'Valet tip');
    return { title: `NEW TIP · ${money(c.amount_cents)}`, body: `${who} · Stripe`, url: '/', tag: `airvalet-tip-${c.key || 'x'}` };
  }
  if (c.mode === 'summary') {
    return { title: 'NEW CHECK-INS', body: 'More check-ins just arrived. Open AirValet to see them.', url: '/', tag: 'airvalet-checkin-batch' };
  }
  const where = c.loc ? ` · ${String(c.loc).slice(0, 20)}` : '';
  const body = showPreview && c.name ? `${String(c.name).slice(0, 40)} · ${ticket || 'New ticket'}${where}` : `${ticket || 'New ticket'}${where}`;
  return { title: 'NEW CHECK-IN', body, url: '/', tag: `airvalet-checkin-${c.ticket || 'new'}` };
}

export async function notifyStaff(deps: StaffDeps, kind: string, id: number): Promise<StaffResult> {
  const log = deps.log ?? (() => {});
  const out: StaffResult = { kind, mode: 'skip', push: 0 };
  try {
    if (!(STAFF_KINDS as readonly string[]).includes(kind) || !Number.isSafeInteger(id) || id <= 0) return out;
    const k = kind as StaffKind;
    const { data, error } = await deps.db.rpc('airvalet_staff_alert_claim', { p_kind: k, p_id: id });
    if (error || !data) return out;
    const claim = data as StaffClaim;
    out.mode = claim.mode;
    if (claim.mode === 'skip' || !claim.key) return out;
    if (!deps.vapid) {
      await deps.db.rpc('airvalet_notify_finish', { p_dedupe_key: claim.key, p_status: 'skipped', p_segments: null, p_sid: null, p_detail: 'push not configured' });
      return out;
    }
    const { data: targets } = await deps.db.rpc('airvalet_push_staff_targets', { p_kind: k });
    let ok = 0;
    for (const t of (targets ?? []) as { id: string; endpoint: string; p256dh: string; auth: string; show_preview: boolean }[]) {
      const r: PushResult = await (deps.pushImpl ?? sendPush)(t, staffPushPayload(k, claim, !!t.show_preview), deps.vapid);
      await deps.db.rpc('airvalet_push_result', { p_id: t.id, p_ok: r.ok, p_gone: r.gone });
      if (r.ok) ok += 1;
    }
    out.push = ok;
    await deps.db.rpc('airvalet_notify_finish', { p_dedupe_key: claim.key, p_status: ok ? 'sent' : 'skipped', p_segments: null, p_sid: null, p_detail: `${claim.mode}: ${ok} device(s)` });
    log('staff.alert', { kind, mode: claim.mode, push: ok });
    return out;
  } catch (e) {
    log('staff.alert.error', { kind, error: (e as Error)?.name || 'Error' });
    return out;
  }
}

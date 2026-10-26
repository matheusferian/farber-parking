// Staff push alerts on the phones that asked for them (airvalet_push_subs):
//   CHECK_IN   new check-in          (ADMIN phones)
//   TIP        Stripe tip received   (ADMIN phones)
//   REMINDERS  every minute (pg_cron): operational reminders that are due, to
//              the phones whose categories match (airvalet_staff_reminders_claim)
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

// One phone at a time: a bad subscription (e.g. a key the encryption rejects) never stops the others or the audit.
async function pushOne(deps: StaffDeps, t: { endpoint: string; p256dh: string; auth: string },
  payload: { title: string; body: string; url: string; tag: string }): Promise<PushResult> {
  try { return await (deps.pushImpl ?? sendPush)(t, payload, deps.vapid!); } catch { return { ok: false, status: 0, gone: false }; }
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
      const r = await pushOne(deps, t, staffPushPayload(k, claim, !!t.show_preview));
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

// ── Reminders (cron tick) ───────────────────────────────────────────────
// grp / gtext: reminders of the same flight or task in one run (e.g. three cars
// landing 5:02 PM) become one alert; gtext has a {t} for the ticket list.
export type ReminderItem = { code: string; category: string; key: string; ticket: string | null; body: string; grp?: string | null; gtext?: string | null };
export const REMINDER_BATCH_MAX = 3;   // more than this many alerts for one phone in one run → one summary alert

export function reminderPushPayloads(items: ReminderItem[]): { title: string; body: string; url: string; tag: string }[] {
  const groups: { tag: string; body: string }[] = [], byGrp = new Map<string, ReminderItem[]>();
  for (const i of items) {
    if (!i.grp || !i.gtext) { groups.push({ tag: i.key, body: i.body }); continue; }
    const g = byGrp.get(i.grp);
    if (g) { g.push(i); continue; }
    byGrp.set(i.grp, [i]); groups.push({ tag: i.grp, body: '' });
  }
  for (const g of groups) {
    const members = byGrp.get(g.tag); if (!members) continue;
    g.body = members.length === 1 ? members[0].body : members[0].gtext!.replace('{t}', members.map((m) => m.ticket || '?').join(', '));
  }
  if (groups.length > REMINDER_BATCH_MAX) {
    const list = groups.slice(0, 4).map((g) => g.body).join(' · ');
    return [{ title: `${groups.length} AIRVALET REMINDERS`, body: (list + (groups.length > 4 ? ' · …' : '')).slice(0, 200), url: '/', tag: 'airvalet-reminders' }];
  }
  return groups.map((g) => ({ title: 'AIRVALET REMINDER', body: g.body.slice(0, 200), url: '/', tag: `airvalet-${g.tag}`.slice(0, 120) }));
}

export async function notifyReminders(deps: StaffDeps): Promise<{ kind: string; items: number; push: number }> {
  const log = deps.log ?? (() => {});
  const out = { kind: 'REMINDERS', items: 0, push: 0 };
  try {
    const { data, error } = await deps.db.rpc('airvalet_staff_reminders_claim', {});
    if (error || !Array.isArray(data) || !data.length) return out;
    const items = data as ReminderItem[];
    out.items = items.length;
    const sentTo = new Map<string, number>();   // reminder key → phones that got it
    if (deps.vapid) {
      const { data: targets } = await deps.db.rpc('airvalet_push_reminder_targets', {});
      for (const t of (targets ?? []) as { id: string; endpoint: string; p256dh: string; auth: string; categories: string[] }[]) {
        const mine = items.filter((i) => (t.categories || []).includes(i.category));
        if (!mine.length) continue;
        let okAll = true;
        for (const payload of reminderPushPayloads(mine)) {
          const r = await pushOne(deps, t, payload);
          await deps.db.rpc('airvalet_push_result', { p_id: t.id, p_ok: r.ok, p_gone: r.gone });
          if (r.ok) out.push += 1; else okAll = false;
          if (r.gone) break;
        }
        if (okAll) for (const i of mine) sentTo.set(i.key, (sentTo.get(i.key) || 0) + 1);
      }
    }
    for (const i of items) {
      const n = sentTo.get(i.key) || 0;
      await deps.db.rpc('airvalet_notify_finish', { p_dedupe_key: i.key, p_status: n ? 'sent' : 'skipped', p_segments: null, p_sid: null,
        p_detail: deps.vapid ? `${i.code}: ${n} device(s)` : 'push not configured' });
    }
    log('staff.reminders', { items: out.items, push: out.push });
    return out;
  } catch (e) {
    log('staff.reminders.error', { error: (e as Error)?.name || 'Error' });
    return out;
  }
}

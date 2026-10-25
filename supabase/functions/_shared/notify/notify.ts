// Staff notifications for one event (a guest text, a passenger request):
//   * Web Push to approved devices that enabled alerts (iPad on the Home Screen);
//   * one SMS copy to the Super Admin's verified phone (optional, capped).
// Runs AFTER the event is committed; a failure here never affects the stored
// message or request. Each channel is claimed once per event in
// airvalet_notify_log, so retries / duplicate webhooks never notify twice.
// Never sends anything to passengers.

import { countSegments, isGsm7 } from '../sms/templates.ts';
import type { SmsProvider } from '../sms/provider.ts';
import { sendPush, type PushResult } from '../push/webpush.ts';

// deno-lint-ignore no-explicit-any
type Db = { rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: any; error: any }> };

export type NotifyKind = 'GUEST_MESSAGE' | 'PASS_REQUEST';
export type Vapid = { privateJwk: JsonWebKey; publicKey: string; subject: string };
export type NotifyDeps = {
  db: Db;
  vapid: Vapid | null;                 // null → push skipped
  adminProvider: SmsProvider | null;   // null → admin SMS skipped (texting disabled)
  appUrl: string;                      // e.g. https://airvalet.farberos.com (login required)
  pushImpl?: typeof sendPush;
  log?: (event: string, data: Record<string, unknown>) => void;
};
export type NotifyResult = { push: number; adminSms: 'sent' | 'failed' | 'skipped' };

type Details = { kind: NotifyKind; passenger_id: number | null; phone_e164: string | null; name: string; ticket: string | null; text: string };

// Any character outside GSM-7 becomes its unaccented letter or is dropped, so
// the admin copy never switches to UCS-2 (emoji in a guest text, etc.).
export function toGsm7(s: string): string {
  return Array.from(String(s || '').replace(/\s+/g, ' ').trim())
    .map((ch) => (isGsm7(ch) ? ch : ch.normalize('NFD').replace(/[̀-ͯ]/g, '')))
    .filter((ch) => ch.length === 1 && isGsm7(ch)).join('');
}

// One segment: header + guest + ticket + (truncated) message + login link.
export function adminSmsBody(d: Details, appUrl: string): string {
  const head = d.kind === 'GUEST_MESSAGE' ? 'AIRVALET MESSAGE' : 'AIRVALET REQUEST';
  const label = d.kind === 'GUEST_MESSAGE' ? 'Msg' : 'Req';
  const link = `${appUrl.replace(/\/+$/, '')}/#messages`;
  const fixed = (msg: string) =>
    `${head}\nGuest: ${toGsm7(d.name).slice(0, 30)}\nTicket: ${toGsm7(d.ticket || '-')}\n${label}: ${msg}\nOpen: ${link}`;
  let msg = toGsm7(d.text);
  if (countSegments(fixed(msg)) === 1) return fixed(msg);
  while (msg.length > 0 && countSegments(fixed(msg + '...')) > 1) msg = msg.slice(0, -1);
  return fixed(msg.trimEnd() + '...');
}

export function pushPayload(d: Details, showPreview: boolean): { title: string; body: string; url: string; tag: string } {
  const title = d.kind === 'GUEST_MESSAGE' ? 'NEW GUEST MESSAGE' : 'NEW PASSENGER REQUEST';
  const ticket = d.ticket ? `Ticket #${d.ticket}` : 'Ticket not matched';
  const body = showPreview ? `${d.name} - ${ticket}\n"${d.text.slice(0, 120)}"` : `${ticket} · Tap to read`;
  return { title, body, url: '/#messages', tag: `airvalet-${d.kind.toLowerCase()}` };
}

export async function notifyEvent(deps: NotifyDeps, kind: NotifyKind, refId: string): Promise<NotifyResult> {
  const log = deps.log ?? (() => {});
  const out: NotifyResult = { push: 0, adminSms: 'skipped' };
  try {
    const { data: d, error } = await deps.db.rpc('airvalet_notify_details', { p_kind: kind, p_ref: refId });
    if (error || !d) return out;
    const details = d as Details;

    // ── Push ──
    if (deps.vapid) {
      const { data: claimed } = await deps.db.rpc('airvalet_notify_claim', { p_dedupe_key: `push:${kind}:${refId}`, p_channel: 'push' });
      if (claimed) {
        const { data: targets } = await deps.db.rpc('airvalet_push_targets', {});
        let ok = 0;
        for (const t of (targets ?? []) as { id: string; endpoint: string; p256dh: string; auth: string; show_preview: boolean }[]) {
          const r: PushResult = await (deps.pushImpl ?? sendPush)(t, pushPayload(details, !!t.show_preview), deps.vapid);
          await deps.db.rpc('airvalet_push_result', { p_id: t.id, p_ok: r.ok, p_gone: r.gone });
          if (r.ok) ok += 1;
        }
        out.push = ok;
        await deps.db.rpc('airvalet_notify_finish', { p_dedupe_key: `push:${kind}:${refId}`, p_status: ok ? 'sent' : 'skipped', p_segments: null, p_sid: null, p_detail: `${ok} device(s)` });
      }
    }

    // ── Super Admin SMS copy ──
    if (deps.adminProvider) {
      const key = `admin:${kind}:p${details.passenger_id ?? 'x'}:${refId}`;
      const { data: phone } = await deps.db.rpc('airvalet_admin_alert_claim', {
        p_event: kind, p_passenger_id: details.passenger_id, p_phone_e164: details.phone_e164, p_dedupe_key: key,
      });
      if (typeof phone === 'string' && phone) {
        const body = adminSmsBody(details, deps.appUrl);
        const r = await deps.adminProvider.send({ to: phone, body });
        const sent = r.kind === 'accepted';
        out.adminSms = sent ? 'sent' : 'failed';
        await deps.db.rpc('airvalet_notify_finish', {
          p_dedupe_key: key, p_status: out.adminSms, p_segments: countSegments(body),
          p_sid: sent ? r.sid : null, p_detail: sent ? 'ok' : `${r.errorCode}`,
        });
      }
    }
    log('notify.done', { kind, push: out.push, adminSms: out.adminSms });
    return out;
  } catch (e) {
    log('notify.error', { kind, error: (e as Error)?.name || 'Error' });
    return out;
  }
}

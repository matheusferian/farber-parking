// Ascend reminders by text to STAFF (owner 2026-11-25): the day before, 2 h and 1 h before an Ascend departure.
// What is due and what each text says comes from airvalet_ascend_claim() (one claim per text, so a minute tick
// never repeats it). Runs inside the staff-alert REMINDERS tick (server cron, never the Mac).
// Gate: secret ASCEND_SMS = off (default) | test (only ASCEND_SMS_TEST numbers) | live. Off → nothing is claimed.
// Never sends anything to passengers; never throws.

import { readSmsConfig } from '../sms/config.ts';
import { normalizePhoneE164 } from '../sms/phone.ts';
import { type SmsProvider, TwilioProvider } from '../sms/provider.ts';

// deno-lint-ignore no-explicit-any
type Db = { rpc(fn: string, args: Record<string, unknown>): PromiseLike<{ data: any; error: any }>; from(t: string): any };
export type AscendDeps = { db: Db; mode: string; testList: string[]; provider: SmsProvider | null; log?: (event: string, data: Record<string, unknown>) => void };

export function ascendDepsFromEnv(db: unknown, get: (k: string) => string | undefined, log?: AscendDeps['log']): AscendDeps {
  const cfg = readSmsConfig(get);
  return {
    db: db as Db, log, mode: (get('ASCEND_SMS') || 'off').trim().toLowerCase(),
    testList: (get('ASCEND_SMS_TEST') || '').split(',').map((s) => normalizePhoneE164(s)).filter((p) => p.valid).map((p) => (p as { e164: string }).e164),
    provider: cfg.twilio ? new TwilioProvider({ ...cfg.twilio, timeoutMs: 8_000 }) : null,
  };
}

// Returns how many texts Twilio accepted.
export async function sendAscendTexts(d: AscendDeps): Promise<number> {
  if (d.mode !== 'live' && d.mode !== 'test') return 0;
  const log = d.log ?? (() => {});
  try {
    const { data, error } = await d.db.rpc('airvalet_ascend_claim', {});
    if (error || !Array.isArray(data) || !data.length) return 0;
    const done = await Promise.all((data as { id: number; phone: string; body: string }[]).map(async (t) => {
      const save = async (status: string, sid: string | null, error_code: string | null) => {
        await d.db.from('airvalet_ascend_texts').update({ status, sid, error_code }).eq('id', t.id);
        return status === 'SENT' ? 1 : 0;
      };
      try {
        if (d.mode === 'test' && !d.testList.includes(t.phone)) return await save('BLOCKED', null, 'TEST_ONLY');
        const { data: oo } = await d.db.from('airvalet_sms_opt_outs').select('opted_out').eq('phone_e164', t.phone).maybeSingle();
        if (oo?.opted_out) return await save('BLOCKED', null, 'OPTED_OUT');
        if (!d.provider) return await save('FAILED', null, 'NO_TWILIO');
        let r = await d.provider.send({ to: t.phone, body: t.body });
        // Throttled = definitely not sent: one more try. Anything unknown is never retried (it may have gone out).
        if (r.kind === 'throttled') { await new Promise((ok) => setTimeout(ok, 1500)); r = await d.provider.send({ to: t.phone, body: t.body }); }
        if (r.kind === 'accepted') return await save('SENT', r.sid, null);
        return await save(r.kind === 'unknown' ? 'UNKNOWN' : 'FAILED', null, r.errorCode);
      } catch (e) { log('ascend.text_error', { id: t.id, error: (e as Error)?.name || 'Error' }); return 0; }
    }));
    const sent = done.reduce((a: number, n) => a + n, 0);
    log('ascend.texts', { due: data.length, sent });
    return sent;
  } catch (e) {
    log('ascend.error', { error: (e as Error)?.name || 'Error' });
    return 0;
  }
}

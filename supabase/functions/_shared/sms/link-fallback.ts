// Owner 2026-11-17 (option 1): since 11/14 a carrier blocks (Twilio 30007, "carrier filtered") about 1 in 5
// texts that carry the valet pass link, while every text WITHOUT a link still arrives — even to the same phones
// that got the link before. Links now go as /p/<token> (same as the approved A2P sample). When a link text still
// comes back 30007, the guest automatically gets the text WITHOUT the link, asking to reply PASS; the reply PASS
// gets the link right away (a reply in a conversation the guest started). The blocked alert is closed once the
// no-link copy is accepted; if a copy fails it raises its own alert as usual.

import { countSegments, SENDER } from './templates.ts';

// Template keys that carry the pass link → the same text without it (GSM-7, 1 segment each).
export const NO_LINK_BODY: Record<string, string> = {
  CHECK_IN_PASS: `${SENDER}: Your car is checked in. Reply PASS to get your valet pass link. Msg & data rates may apply. Reply HELP for help, STOP to opt out.`,
  DELIVERED: `${SENDER}: Your car has been delivered. Thank you for choosing us! Reply PASS to see your valet pass.`,
};
export const NO_LINK_VERSION = 'nolink-2026-11-17';

export type BlockedRow = {
  id: string; direction: string; template_key: string | null; message_type: string | null; body: string | null;
  passenger_id: number | null; ticket_snapshot: string | null; phone_e164: string; status: string;
};

// Which blocked text gets a no-link copy (pure: tested without Twilio).
export function noLinkCopyFor(errorCode: string | null, status: string, row: BlockedRow | null): string | null {
  if (errorCode !== '30007' || status !== 'undelivered' || !row || row.direction !== 'outbound') return null;
  const body = NO_LINK_BODY[row.template_key || ''];
  if (!body || !/https?:\/\//.test(row.body || '')) return null;
  return body;
}

type Send = (to: string, body: string, messageId: string) => Promise<{ ok: boolean; sid: string | null; status: string; errorCode: string | null; errorMessage: string | null }>;

// deno-lint-ignore no-explicit-any
export async function sendNoLinkCopy(admin: any, sid: string, status: string, errorCode: string | null, send: Send, log?: (e: string, d: Record<string, unknown>) => void): Promise<void> {
  try {
    if (errorCode !== '30007' || status !== 'undelivered') return;
    const { data: row } = await admin.from('airvalet_sms_messages')
      .select('id,direction,template_key,message_type,body,passenger_id,ticket_snapshot,phone_e164,status')
      .eq('provider_message_sid', sid).maybeSingle();
    const body = noLinkCopyFor(errorCode, status, row);
    if (!body) return;
    // One copy per blocked text: the unique idempotency key stops Twilio callback retries from sending twice.
    const { data: ins, error } = await admin.from('airvalet_sms_messages').insert({
      direction: 'outbound', passenger_id: row.passenger_id, ticket_snapshot: row.ticket_snapshot, phone_e164: row.phone_e164,
      message_type: row.message_type, template_key: row.template_key + '_NOLINK', template_version: NO_LINK_VERSION,
      body, segments: countSegments(body), provider: 'twilio', status: 'pending', idempotency_key: 'nolink:' + row.id,
      sent_by_name: 'Auto (link blocked)',
    }).select('id').maybeSingle();
    if (error || !ins?.id) { log?.('sms.nolink_skip', { code: error?.code || 'none' }); return; }
    const out = await send(row.phone_e164, body, ins.id);
    await admin.rpc('airvalet_sms_mark_result', {
      p_message_id: ins.id, p_status: out.status, p_provider_message_sid: out.sid, p_messaging_service_sid: null,
      p_error_code: out.errorCode, p_error_message: out.errorMessage, p_attempts: 1,
    });
    if (out.ok) {
      await admin.from('airvalet_sms_messages').update({ resolved_at: new Date().toISOString(), resolution: 'acknowledged' })
        .eq('id', row.id).is('resolved_at', null);
    }
    log?.('sms.nolink_sent', { original: row.id, copy: ins.id, ok: out.ok });
  } catch {
    log?.('sms.nolink_error', {});
  }
}

// ── Reply PASS → the link ─────────────────────────────────────────────────────────────────────────────
export const isPassWord = (body: string) => /^\s*pass\W*$/i.test(String(body || ''));
export const passReplyBody = (link: string) => `${SENDER}: Here is your valet pass: ${link}`;
const PASS_WINDOW_DAYS = 14;
// Texts that ask the guest to reply PASS: the no-link copies of a blocked text + the check-in text (option 2).
export const PASS_ASKING_KEYS = ['CHECK_IN_PASS_NOLINK', 'DELIVERED_NOLINK', 'CHECK_IN_ASK_PASS'];

// Only a phone that got a text asking for PASS in the last 14 days, once per such text: a guest who
// already has a working link never gets it rotated by a stray "pass".
// deno-lint-ignore no-explicit-any
export async function passReply(admin: any, fromE164: string, sid: string, passBaseUrl: string, send: Send,
  log?: (e: string, d: Record<string, unknown>) => void): Promise<boolean> {
  try {
    const since = new Date(Date.now() - PASS_WINDOW_DAYS * 86400_000).toISOString();
    const { data: copy } = await admin.from('airvalet_sms_messages')
      .select('id,passenger_id,ticket_snapshot,message_type')
      .eq('direction', 'outbound').eq('phone_e164', fromE164).in('template_key', PASS_ASKING_KEYS).gte('created_at', since)
      .order('created_at', { ascending: false }).limit(1).maybeSingle();
    if (!copy?.passenger_id) return false;
    const placeholder = passReplyBody(passBaseUrl + '*'.repeat(17));
    const { data: ins, error } = await admin.from('airvalet_sms_messages').insert({
      direction: 'outbound', passenger_id: copy.passenger_id, ticket_snapshot: copy.ticket_snapshot, phone_e164: fromE164,
      message_type: copy.message_type, template_key: 'PASS_REPLY', template_version: NO_LINK_VERSION,
      body: placeholder, segments: countSegments(placeholder), provider: 'twilio', status: 'pending',
      idempotency_key: 'passreply:' + copy.id, sent_by_name: 'Auto (reply PASS)',
    }).select('id').maybeSingle();
    // Already answered once (a second PASS) → the normal Inbox path: staff see it and help.
    if (error || !ins?.id) { log?.('sms.pass_reply_skip', { code: error?.code || 'none' }); return false; }
    // The guest's PASS shows in the Inbox conversation, already read (the link answers it; no staff alert).
    await admin.from('airvalet_sms_messages').insert({
      direction: 'inbound', passenger_id: copy.passenger_id, ticket_snapshot: copy.ticket_snapshot, phone_e164: fromE164,
      message_type: 'INBOUND', body: 'PASS', provider: 'twilio', provider_message_sid: sid, status: 'received',
      match_method: 'last_outbound', received_at: new Date().toISOString(), read_at: new Date().toISOString(),
    });
    const { data: token } = await admin.rpc('airvalet_pass_mint', { p_passenger_id: copy.passenger_id });
    if (!token || !/^[A-Za-z0-9]{17}$/.test(String(token))) {
      await admin.rpc('airvalet_sms_mark_result', { p_message_id: ins.id, p_status: 'failed', p_provider_message_sid: null,
        p_messaging_service_sid: null, p_error_code: 'PASS_LINK_UNAVAILABLE', p_error_message: 'passenger link not available', p_attempts: 0 });
      log?.('sms.pass_reply_no_link', { copy: copy.id });
      return true;
    }
    const out = await send(fromE164, passReplyBody(passBaseUrl + token), ins.id);
    await admin.rpc('airvalet_sms_mark_result', {
      p_message_id: ins.id, p_status: out.status, p_provider_message_sid: out.sid, p_messaging_service_sid: null,
      p_error_code: out.errorCode, p_error_message: out.errorMessage, p_attempts: 1,
    });
    log?.('sms.pass_reply_sent', { copy: copy.id, reply: ins.id, ok: out.ok });
    return true;
  } catch {
    log?.('sms.pass_reply_error', {});
    return false;
  }
}

// Owner 2026-11-12: Jet Runway Café texts (START / READY / On my way / Done) also show in the AirValet Inbox, in
// the conversation of the guest's car — the passenger the phone matches (same rule as every reply:
// airvalet_sms_match_passenger). A café guest with no car here has no conversation: the texts stay on the ride.
// READY is stored already read and as INBOUND_RIDE (not INBOUND): the red ride card + ride push already
// warned the team, so it never fires a second "guest message" alert.

import { countSegments } from './templates.ts';

const OK_MATCH = ['last_outbound', 'active_passenger', 'recent_outbound'];

// deno-lint-ignore no-explicit-any
export async function rideInboxMatch(admin: any, phone: string): Promise<{ id: number; method: string } | null> {
  const { data, error } = await admin.rpc('airvalet_sms_match_passenger', { p_phone_e164: phone });
  const row = Array.isArray(data) ? data[0] : data;
  if (error || !row?.passenger_id || !OK_MATCH.includes(row.match_method)) return null;
  return { id: Number(row.passenger_id), method: String(row.match_method) };
}

// One row per text; never throws (the Inbox copy must not break a ride).
export function rideOutboundRow(a: { rideId: string; kind: string; phone: string; body: string; sid: string; staffName: string | null; passengerId: number; ticket: string | null; now: string }) {
  return {
    direction: 'outbound', passenger_id: a.passengerId, ticket_snapshot: a.ticket, phone_e164: a.phone,
    message_type: 'JET_RUNWAY', template_key: 'RIDE_' + a.kind, body: a.body, segments: countSegments(a.body),
    provider: 'twilio', provider_message_sid: a.sid, status: 'sent', idempotency_key: `ride:${a.rideId}:${a.kind}`,
    sent_by_name: a.staffName, sent_at: a.now,
  };
}
export function rideInboundRow(a: { phone: string; body: string; sid: string; passengerId: number; method: string; ticket: string | null; now: string }) {
  return {
    direction: 'inbound', passenger_id: a.passengerId, ticket_snapshot: a.ticket, phone_e164: a.phone,
    message_type: 'INBOUND_RIDE', body: a.body.slice(0, 1600), provider: 'twilio', provider_message_sid: a.sid,
    status: 'received', match_method: a.method, received_at: a.now, read_at: a.now,
  };
}

// deno-lint-ignore no-explicit-any
async function ticketOf(admin: any, id: number): Promise<string | null> {
  const { data } = await admin.from('passengers').select('ticket').eq('id', id).maybeSingle();
  return data?.ticket ?? null;
}
// deno-lint-ignore no-explicit-any
export async function rideInboxOutbound(admin: any, a: { rideId: string; kind: string; phone: string; body: string; sid: string; staffName: string | null }, log?: (e: string, d: Record<string, unknown>) => void): Promise<void> {
  try {
    const m = await rideInboxMatch(admin, a.phone); if (!m) return;
    const { error } = await admin.from('airvalet_sms_messages').insert(rideOutboundRow({ ...a, passengerId: m.id, ticket: await ticketOf(admin, m.id), now: new Date().toISOString() }));
    if (error) log?.('ride.inbox_out_failed', { ride: a.rideId, kind: a.kind, code: error.code });
  } catch { log?.('ride.inbox_out_failed', { ride: a.rideId, kind: a.kind }); }
}
// deno-lint-ignore no-explicit-any
export async function rideInboxInbound(admin: any, a: { phone: string; body: string; sid: string }, log?: (e: string, d: Record<string, unknown>) => void): Promise<void> {
  try {
    const m = await rideInboxMatch(admin, a.phone); if (!m) return;
    const { error } = await admin.from('airvalet_sms_messages').insert(rideInboundRow({ ...a, passengerId: m.id, method: m.method, ticket: await ticketOf(admin, m.id), now: new Date().toISOString() }));
    if (error) log?.('ride.inbox_in_failed', { code: error.code });
  } catch { log?.('ride.inbox_in_failed', {}); }
}

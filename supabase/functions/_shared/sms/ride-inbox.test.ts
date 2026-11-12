// deno test supabase/functions/_shared/sms/ride-inbox.test.ts — Jet Runway texts in the Inbox (owner 2026-11-12).
import { assertEquals } from 'jsr:@std/assert@1';
import { rideInboundRow, rideInboxMatch, rideOutboundRow } from './ride-inbox.ts';

const fake = (row: unknown) => ({ rpc: async () => ({ data: row, error: null }) });
Deno.test('only a clear match links the ride texts to a car (no car / several cars → ride only)', async () => {
  assertEquals(await rideInboxMatch(fake([{ passenger_id: 3809, match_method: 'active_passenger' }]), '+15550001111'), { id: 3809, method: 'active_passenger' });
  assertEquals(await rideInboxMatch(fake([{ passenger_id: 7, match_method: 'last_outbound' }]), '+15550001111'), { id: 7, method: 'last_outbound' });
  assertEquals(await rideInboxMatch(fake([{ passenger_id: null, match_method: 'ambiguous' }]), '+15550001111'), null);
  assertEquals(await rideInboxMatch(fake([{ passenger_id: null, match_method: 'unmatched' }]), '+15550001111'), null);
});
Deno.test('rows: outbound is a sent text with a unique key per ride step; READY comes in already read, never a guest-message alert', () => {
  const now = '2026-11-12T16:30:00Z';
  const o = rideOutboundRow({ rideId: 'r1', kind: 'START', phone: '+15550001111', body: 'Hi', sid: 'SMx', staffName: 'iphone', passengerId: 1, ticket: '1112-3', now });
  assertEquals([o.direction, o.message_type, o.template_key, o.status, o.idempotency_key, o.provider_message_sid, o.segments], ['outbound', 'JET_RUNWAY', 'RIDE_START', 'sent', 'ride:r1:START', 'SMx', 1]);
  const i = rideInboundRow({ phone: '+15550001111', body: 'READY', sid: 'SMy', passengerId: 1, method: 'active_passenger', ticket: '1112-3', now });
  assertEquals([i.direction, i.message_type, i.status, i.read_at, i.provider_message_sid], ['inbound', 'INBOUND_RIDE', 'received', now, 'SMy']);
});

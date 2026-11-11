import { assert, assertEquals } from 'jsr:@std/assert@1';
import { rideSessionForm, rideText, smsAllowed, tipCents } from './lib.ts';
import { countSegments, isGsm7 } from '../_shared/sms/templates.ts';

Deno.test('ride texts are one GSM-7 segment each', () => {
  for (const s of [rideText('START'), rideText('ONWAY'), rideText('DONE', 'airvalet.farberos.com/r#' + 'x'.repeat(16))]) {
    assert(Array.from(s).every((c) => isGsm7(c)), s);
    assertEquals(countSegments(s), 1, s);
  }
  assert(rideText('START').includes('READY') && rideText('START').includes('(954) 352-1010') && rideText('START').includes('STOP'));
});

Deno.test('SMS gate: off / test / live', () => {
  assertEquals(smsAllowed('off', ['+17542708385'], '+17542708385').ok, false);
  assertEquals(smsAllowed('', [], '+17542708385').ok, false);
  assertEquals(smsAllowed('test', ['+17542708385'], '+17542708385').ok, true);
  assertEquals(smsAllowed('test', ['+17542708385'], '+13055550142').ok, false);
  assertEquals(smsAllowed('live', [], '+13055550142').ok, true);
});

Deno.test('tip amount bounds', () => {
  assertEquals(tipCents(1000), 1000);
  assertEquals(tipCents(50), null);
  assertEquals(tipCents(60000), null);
  assertEquals(tipCents('1000'), null);
  assertEquals(tipCents(10.5), null);
});

Deno.test('Stripe form: AirValet TIP metadata, no passenger', () => {
  const f = rideSessionForm('abc', 1000, 'https://airvalet.farberos.com/r');
  assertEquals(f.get('metadata[source]'), 'AIRVALET');
  assertEquals(f.get('metadata[type]'), 'TIP');
  assertEquals(f.get('metadata[ticket]'), 'JET RUNWAY');
  assertEquals(f.get('metadata[passenger_id]'), null);
  assertEquals(f.get('line_items[0][price_data][unit_amount]'), '1000');
  assertEquals(f.get('success_url'), 'https://airvalet.farberos.com/r?gratuity=thanks');
});

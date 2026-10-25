// deno test tests/portal/sms_segments.test.ts   (pure, no network)
// Every APPROVED template body rendered with the real production link length
// must be GSM-7 only and fit the expected segment count.
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { countSegments, isGsm7, PassengerCtx, renderMessage, TEMPLATES } from '../../supabase/functions/_shared/sms/templates.ts';

const LINK = 'https://airvalet.farberos.com/a#' + 'Ab3dE5gH7jK9mN1pQ'; // 17-char token (PASS_TOKEN_LEN)
const base: PassengerCtx = {
  name: 'JOHN SMITH', ticket: '1025-11', ret: '10/31/2026', ret_time: '18:00', car: 'AUDI Q7', status: 'PENDING',
  return_operator: 'MAKERS', delivery_at_customs: false, customs_exception_requested_at: null, delivery_type: null,
  customs_welcome_sent: false, tip_received: null,
};
const gsmOnly = (b: string) => Array.from(b).every(isGsm7);

const cases: Array<[string, keyof typeof TEMPLATES, Partial<PassengerCtx>, string, number]> = [
  ['CHECK_IN', 'CHECK_IN', {}, 'CHECK_IN_PASS', 1],
  ['VEHICLE_READY Hangar 19', 'VEHICLE_READY', {}, 'HANGAR19_WELCOME_BACK', 1],
  ['VEHICLE_READY Customs (Ascend)', 'VEHICLE_READY', { ticket: 'A-1025-3', return_operator: 'ASCEND' }, 'CUSTOMS_WELCOME', 1],
  ['VEHICLE_READY Customs exception (Makers)', 'VEHICLE_READY', { delivery_at_customs: true }, 'CUSTOMS_EXCEPTION', 1],
  ['VEHICLE_READY Customs delivered (car waiting at Customs)', 'VEHICLE_READY', { status: 'DELIVERED', delivery_type: 'CUSTOMS', return_operator: 'ASCEND' }, 'CUSTOMS_WELCOME', 1],
  ['VEHICLE_DELIVERED', 'VEHICLE_DELIVERED', { status: 'DELIVERED' }, 'DELIVERED', 1],
];

for (const [label, type, over, variant, maxSeg] of cases) {
  Deno.test(`segments: ${label} → GSM-7, ${maxSeg} segment`, () => {
    const tpl = TEMPLATES[type];
    assertEquals(tpl.status, 'APPROVED', `${type} must be APPROVED`);
    const out = renderMessage(tpl, { ...base, ...over }, { passUrl: LINK });
    assertEquals(out.variant, variant);
    assert(gsmOnly(out.body), `${label}: non GSM-7 char in ${JSON.stringify(out.body)}`);
    const seg = countSegments(out.body);
    console.log(`  ${label}: ${out.body.length} chars, ${seg} segment(s)`);
    assertEquals(seg, maxSeg, `${label}: ${out.body.length} chars`);
  });
}

Deno.test('segments: REPLY typical staff answers are 1 segment; 3-segment cap (459 GSM-7 chars)', () => {
  const tpl = TEMPLATES.REPLY;
  assertEquals(tpl.status, 'APPROVED');
  for (const b of ['Hi! Your car will be ready at Hangar 19 when you land.', 'Got it, thank you. See you Friday at 6:00 PM.']) {
    const out = renderMessage(tpl, base, {}, b);
    assert(gsmOnly(out.body)); assertEquals(countSegments(out.body), 1);
  }
  assertEquals(countSegments(renderMessage(tpl, base, {}, 'x'.repeat(459)).body), 3);
  // 460..480 GSM-7 chars = 4 segments → refused even though FREE_TEXT_MAX is 480.
  let code = '';
  try { renderMessage(tpl, base, {}, 'x'.repeat(460)); } catch (e) { code = (e as { code: string }).code; }
  assertEquals(code, 'BODY_TOO_LONG');
});

Deno.test('only the expected templates are APPROVED (no surprise go-live)', () => {
  const approved = Object.values(TEMPLATES).filter((t) => t.status === 'APPROVED').map((t) => t.type).sort();
  assertEquals(approved, ['CHECK_IN', 'REPLY', 'VEHICLE_DELIVERED', 'VEHICLE_READY']);
});

Deno.test('a passenger name with non-GSM letters never changes CHECK_IN (no name in the body)', () => {
  const out = renderMessage(TEMPLATES.CHECK_IN, { ...base, name: 'JOÃO ŁUKASZ 😀' }, { passUrl: LINK });
  assert(gsmOnly(out.body)); assertEquals(countSegments(out.body), 1);
});

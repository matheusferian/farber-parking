// node --test tests/key-copy.test.mjs
// Key Copy + Flight Tag V2 (utils.js tagLayout / tagPageXml). Layout rules
// validated with owner test prints on the TM-m30II, 2026-10-28.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const ctx = {};
vm.createContext(ctx);
vm.runInContext(readFileSync(new URL('../utils.js', import.meta.url), 'utf8'), ctx);

const NOW = new Date(2026, 9, 28, 14, 5);
const opts = (o) => Object.assign({ ascend: false, pickupAuth: false, approx: false, wash: '', now: NOW }, o || {});
const base = { id: 1, name: 'ANA LIMA', ticket: '1028-2', loc: 'HANGAR 7', ret: '10/30/2026', car: 'TESLA MODEL Y', color: 'WHITE', phone: '9545550142', return_operator: 'MAKERS' };
const rec = (o) => Object.assign({}, base, o || {});
const texts = (rows) => rows.filter((l) => !l.feed).map((l) => [...(l.L || []), ...(l.R || [])].map((s) => s.t).join('|')).join('\n');
const key = (r, o) => ctx.tagLayout('key', r, opts(o));
const flight = (r, o) => ctx.tagLayout('flight', r, opts(o));

function assertSound(lay, label) {
  assert.ok(lay.fits, label + ': fits the sleeve');
  assert.ok(ctx.tagRowsHeight(lay.rows) <= ctx.TAG_READ_H, label + ': height');
  for (const l of lay.rows) {
    if (l.feed) continue;
    for (const [s, x] of ctx.tagPlace(l)) {
      assert.ok(x >= 0 && x + ctx.tagSegW(s) <= ctx.TAG_READ_W, label + ': "' + s.t + '" inside the width');
    }
  }
  const t = texts(lay.rows);
  assert.doesNotMatch(t, /\bN\/A\b|\bNULL\b|\bnull\b|undefined|NaN|NOT ASSIGNED/, label + ': no placeholder text');
  const xml = ctx.tagPageXml(lay.rows);
  for (const el of xml.match(/<text[^>]*>/g)) {
    for (const a of ['font=', 'width=', 'height=', 'em=', 'reverse=']) assert.ok(el.includes(a), label + ': every <text> sets ' + a);
  }
  assert.match(xml, /<page><area x="0" y="0" width="576" height="384"\/><direction dir="top_to_bottom"\/>/);
  assert.match(xml, /<\/page><cut type="feed"\/>/);
  assert.doesNotMatch(xml, /<feed unit="(2[6-9]\d|[3-9]\d\d)"/, label + ': no feed over 255 dots');
  return t;
}

test('short name, full vehicle: every core field once', () => {
  const t = assertSound(key(rec()), 'short');
  for (const s of ['MAKERS AIR VALET', 'ANA LIMA', 'HANGAR 7', '1028-2', 'RETURN', 'FRI OCT 30', 'TESLA MODEL Y · WHITE', '(954) 555-0142']) assert.ok(t.includes(s), s);
  assert.doesNotMatch(t, /OBS|CAR WASH|CUSTOMS|PRINTED/);
  const lay = key(rec());
  const seg = (x) => lay.rows.flatMap((l) => [...(l.L || []), ...(l.R || [])]).find((s) => s.t.includes(x));
  assert.ok(seg('FRI OCT 30').rev && seg('FRI OCT 30').w === 2, 'return date = black bar');
  assert.ok(!seg('HANGAR 7').rev && seg('HANGAR 7').w === 2, 'hangar = plain big text');
});

test('long name wraps on words, never cut mid-word', () => {
  const lay = key(rec({ name: 'MAXIMILIAN ALEXANDER VON HOHENBERG-SCHWARZENEGGER III' }));
  const t = assertSound(lay, 'long name');
  for (const w of ['MAXIMILIAN', 'ALEXANDER', 'VON', 'HOHENBERG-SCHWARZENEGGER', 'III']) assert.ok(t.split(/[\n|]/).some((l) => l.split(' ').includes(w)), w);
});

test('incomplete vehicle / missing fields print nothing in their place', () => {
  let t = assertSound(key(rec({ car: 'ACURA', color: '' })), 'make only');
  assert.ok(t.includes('ACURA') && !t.includes('ACURA ·'));
  t = assertSound(key(rec({ name: null, ticket: '', loc: null, ret: '', car: null, color: null, phone: null, obs: null })), 'all null');
  assert.ok(t.includes('NO HANGAR') && t.includes('NO DATE') && t.includes('CONFIRM'));
});

test('notes: none → no OBS; long → 2 lines + marker on paper', () => {
  assert.doesNotMatch(texts(key(rec({ obs: '' })).rows), /OBS/);
  const t = assertSound(key(rec({ obs: 'Passenger asked to keep the car in the shade. Rear left tire pressure light on at drop off. Garage remote in center console. Do not move the seat.' })), 'long obs');
  assert.ok(t.includes('OBS:') && t.includes('>> MORE NOTES IN AIRVALET'));
});

test('car wash: each real state prints its own text, none/declined prints nothing', () => {
  const cases = { '': null, REQUESTED: 'CAR WASH REQUESTED', SEND_PRICE: 'CAR WASH? PRICE PENDING', CARWASH: 'CAR WASH · CONFIRMED', WASHED: 'CAR WASH · DONE' };
  for (const [wash, want] of Object.entries(cases)) {
    const lay = key(rec(), { wash });
    const t = assertSound(lay, 'wash ' + wash);
    if (want) assert.ok(t.includes(want), wash); else assert.doesNotMatch(t, /CAR WASH/);
    const bar = lay.rows.find((l) => (l.L || []).some((s) => s.t.includes('CAR WASH')));
    if (wash === 'CARWASH') assert.ok(bar.L[0].rev, 'confirmed wash is the black bar');
    if (wash && wash !== 'CARWASH') assert.ok(!bar.L[0].rev, 'unconfirmed wash is never highlighted');
  }
});

test('hangars, Customs, Ascend, Other, authorized pickup', () => {
  for (const loc of ['HANGAR 19', 'HANGAR 18', 'HANGAR 16', 'HANGAR 7', 'HH', 'CUSTOMS']) assertSound(key(rec({ loc })), loc);
  let t = assertSound(key(rec({ ticket: 'A-1027-5', return_operator: 'ASCEND' }), { ascend: true }), 'ascend');
  assert.ok(t.includes('ASCEND · PRIVATE FLIGHT') && t.includes('[A] ANA LIMA') && t.includes('DELIVER TO CUSTOMS'));
  t = assertSound(key(rec({ delivery_at_customs: true })), 'exception');
  assert.ok(t.includes('MAKERS EXCEPTION - APPROVED'));
  t = assertSound(key(rec({ customs_exception_requested_at: '2026-10-28' })), 'pending');
  assert.ok(t.includes('CUSTOMS REQUESTED - PENDING'));
  t = assertSound(key(rec({ return_operator: 'OTHER', not_returning_with_makers_air: true })), 'other');
  assert.ok(t.includes('RETURNING WITH OTHER'));
  t = assertSound(key(rec({ pickup_auth_name: 'Linda Kline', pickup_auth_phone: '5615550112' }), { pickupAuth: true }), 'auth');
  assert.ok(t.includes('AUTH PICKUP: LINDA KLINE') && t.includes('CHECK ID'));
});

test('return date and time: next year shows the year, approx flagged, time 12 h', () => {
  let t = assertSound(key(rec({ ret: '1/4/2027' })), 'next year');
  assert.ok(t.includes('MON JAN 4') && t.includes('2027'));
  t = assertSound(key(rec({ departure_time: '17:30' })), 'time');
  assert.ok(t.includes('5:30 PM'));
  t = assertSound(key(rec(), { approx: true }), 'approx');
  assert.ok(t.includes('APPROX'));
  assert.equal(ctx.tagTime('00:05'), '12:05 AM');
  assert.equal(ctx.tagTime('12:00'), '12:00 PM');
  assert.equal(ctx.tagTime('25:00'), '');
});

test('worst case still fits (long name + everything)', () => {
  const r = rec({ name: 'MAXIMILIAN ALEXANDER VON HOHENBERG', ticket: 'A-1028-11', return_operator: 'MAKERS', delivery_at_customs: true, departure_time: '17:30', pickup_auth_name: 'LINDA KLINE', pickup_auth_phone: '5615550112', car: 'MERCEDES-BENZ GLS 600 MAYBACH', color: 'OBSIDIAN BLACK', obs: 'Key fob battery weak. Child seat in trunk, do not remove. Garage remote in console.' });
  assertSound(key(r, { ascend: true, pickupAuth: true, wash: 'CARWASH' }), 'key worst');
  assertSound(flight(Object.assign({ return_flight: 'N512MA' }, r), { ascend: true, pickupAuth: true, wash: 'CARWASH' }), 'flight worst');
});

test('flight tag: tail + return time share the black bar; hangar is a plain line; no print stamp', () => {
  const lay = flight(rec({ return_flight: 'n512ma', departure_time: '17:30' }), { wash: 'CARWASH' });
  const t = assertSound(lay, 'flight');
  const seg = (s) => lay.rows.flatMap((l) => [...(l.L || []), ...(l.R || [])]).find((x) => x.t.includes(s));
  assert.ok(seg('N512MA').rev && seg('N512MA').w === 2 && seg('N512MA').t.includes('5:30 PM'), 'tail + time = one big black bar');
  assert.doesNotMatch(t, /PRINTED/);
  assert.ok(!seg('HANGAR 7').rev && seg('HANGAR 7').w === 1, 'hangar = plain');
  assert.ok(t.includes('HANGAR 7 · TICKET 1028-2') && t.includes('[ CAR WASH · CONFIRMED ]'));
  const none = assertSound(flight(rec()), 'no flight');
  assert.ok(none.includes('NO FLIGHT') && none.includes('TIME TBD'));
  const longTail = assertSound(flight(rec({ return_flight: 'N1234567890AB', departure_time: '12:45', ret: '1/4/2027' })), 'long tail');
  assert.ok(longTail.includes('N1234567890AB') && longTail.includes('12:45 PM') && longTail.includes('MON JAN 4 2027'));
});

test('XML escapes passenger text', () => {
  const xml = ctx.tagPageXml(key(rec({ name: 'A&B <TEST>' })).rows);
  assert.ok(xml.includes('A&amp;B &lt;TEST&gt;') && !xml.includes('<TEST>'));
});

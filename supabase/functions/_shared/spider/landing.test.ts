// deno test supabase/functions/_shared/spider/
import { assertEquals } from 'jsr:@std/assert@1';
import { landingSoonOk } from './spider.ts';

const T = (hhmm: string) => Date.parse(`2026-11-21T${hhmm}:00-05:00`);
Deno.test('11/21 JH: just took off from FXE (9:55), turned back over the field → NOT landing soon', () => {
  // leg 1534 GHC→FXE leaves Great Harbour 10:45; JH took off from FXE ~9:55, 5 nm out, pointing at FXE in the turn.
  assertEquals(landingSoonOk({ now: T('09:59'), dep: T('10:45'), departedAt: '2026-11-21T14:55:00Z', dist: 5, prevDist: 4, kt: 110, pointsAtFxe: true }), false);
  // even if the distance shrank in the turn and the leg time were ignored, 4 minutes of flight is a take-off
  assertEquals(landingSoonOk({ now: T('09:59'), dep: null, departedAt: '2026-11-21T14:55:00Z', dist: 5, prevDist: 6, kt: 110, pointsAtFxe: true }), false);
});
Deno.test('real arrival: left the island 10:45, 55 min flying, 9 nm out and closing → landing soon', () => {
  assertEquals(landingSoonOk({ now: T('11:40'), dep: T('10:45'), departedAt: '2026-11-21T15:45:00Z', dist: 9, prevDist: 11, kt: 120, pointsAtFxe: true }), true);
});
Deno.test('pointing at FXE but moving away, or on the field, or slow → no', () => {
  const base = { now: T('11:40'), dep: T('10:45'), departedAt: '2026-11-21T15:45:00Z', kt: 120, pointsAtFxe: true };
  assertEquals(landingSoonOk({ ...base, dist: 9, prevDist: 8 }), false);
  assertEquals(landingSoonOk({ ...base, dist: 0.5, prevDist: 2 }), false);
  assertEquals(landingSoonOk({ ...base, dist: 9, prevDist: 11, kt: 20 }), false);
  assertEquals(landingSoonOk({ ...base, dist: 9, prevDist: null }), false);
});

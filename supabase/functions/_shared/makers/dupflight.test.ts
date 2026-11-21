// deno test supabase/functions/_shared/makers/  — synthetic names only.
// Owner 2026-11-21: Makers used flight 27 for two planes (DD COX→FXE 8:45 AM, JR GHC→FXE 5:30 PM) and flight 1534
// for two (JH GHC→FXE 11:45 AM, JH TYM→FXE 5:00 PM). The robot put everyone on the first one; a car was brought
// out for nothing. Same shapes as that day, fictitious people.
import { assertEquals } from 'jsr:@std/assert@1';
import { carUpdate, diffMoves, moveLine, seenOf } from './moves.ts';
import { HeldCar, legFor, runWatch, type SuiteLike } from './sync.ts';
import type { Leg, PaxRow } from './suite.ts';

const D = '11/21/2026';
const LEGS: Leg[] = [
  { date: D, dep: '07:30', arr: '08:45', flight: '27', from: 'COX', to: 'FXE', tail: 'N821DD' },
  { date: D, dep: '15:40', arr: '16:10', flight: '27', from: 'TYM', to: 'GHC', tail: 'N624JR' },
  { date: D, dep: '16:30', arr: '17:30', flight: '27', from: 'GHC', to: 'FXE', tail: 'N624JR' },
  { date: D, dep: '10:45', arr: '11:45', flight: '1534', from: 'GHC', to: 'FXE', tail: 'N208JH' },
  { date: D, dep: '15:15', arr: '17:00', flight: '1534', from: 'TYM', to: 'FXE', tail: 'N208JH' },
  { date: D, dep: '08:00', arr: '09:00', flight: '777', from: 'COX', to: 'FXE', tail: 'N740RV' },
  { date: D, dep: '14:00', arr: '15:00', flight: '777', from: 'COX', to: 'FXE', tail: 'N146WM' },
  { date: D, dep: '10:01', arr: '11:20', flight: '2113', from: 'ASD', to: 'FXE', tail: 'N146WM' },
  { date: D, dep: '06:45', arr: '07:40', flight: '26', from: 'FXE', to: 'GHC', tail: 'N624JR' },
  { date: D, dep: '13:00', arr: '13:50', flight: '26', from: 'FXE', to: 'COX', tail: 'N821DD' },
];
const p = (flight: string, from: string, to: string, last: string, first: string): PaxRow => ({ date: D, flight, from, to, last, first, retDate: '' });
const IN: PaxRow[] = [
  p('27', 'COX', 'FXE', 'MORNING', 'MIKE'),
  p('27', 'GHC', 'FXE', 'HUBBARD', 'ALEX'),          // the 5:30 PM JR plane, not the 8:45 DD
  p('27', 'TYM', 'FXE', 'STOPOVER', 'TINA'),         // boards the JR at TYM, stops at GHC → still the JR
  p('1534', 'GHC', 'FXE', 'GRAYSON', 'LEA'),
  p('1534', 'TYM', 'FXE', 'CHESTER', 'JON'),         // the 5:00 PM, not the 11:45
  p('777', 'COX', 'FXE', 'NOTSURE', 'PAT'),          // two planes from COX: the list cannot tell
  p('2113', 'ASD', 'FXE', 'SINGLE', 'SAM'),          // one plane with that number: unchanged
];
const car = (id: number, name: string, extra: Partial<HeldCar> = {}): HeldCar =>
  ({ id, ticket: 'T' + id, name, ret: '11/21/2026', status: 'PENDING', return_flight: null, departure_time: null, return_operator: 'MAKERS', checkin: '2026-11-20', ...extra });
const POOL = [car(1, 'MIKE MORNING'), car(2, 'ALEX HUBBARD', { return_flight: 'DD', departure_time: '08:45' }), car(3, 'TINA STOPOVER'),
  car(4, 'LEA GRAYSON'), car(5, 'JON CHESTER', { return_flight: 'JH', departure_time: '11:45' }), car(6, 'PAT NOTSURE'), car(7, 'SAM SINGLE')];
const suite: SuiteLike = { schedule: async () => LEGS, passengers: async (_d, o) => (o.to ? IN : []), trips: async () => [] };

Deno.test('same flight number on two planes: each passenger on the plane that serves his island', async () => {
  const w = await runWatch(suite, { date: '2026-11-21', pool: POOL, feedback: [] });
  const by = new Map(w.match.matches.map((m) => [m.system_name, m]));
  const at = (n: string) => { const m = by.get(n)!; return `${m.flight_number} ${m.registration} ${m.arrival_time}${m.unsure ? ' UNSURE' : ''}`; };
  assertEquals(at('MIKE MORNING'), '27 N821DD 08:45');
  assertEquals(at('ALEX HUBBARD'), '27 N624JR 17:30');
  assertEquals(at('TINA STOPOVER'), '27 N624JR 17:30');
  assertEquals(at('LEA GRAYSON'), '1534 N208JH 11:45');
  assertEquals(at('JON CHESTER'), '1534 N208JH 17:00');
  assertEquals(at('SAM SINGLE'), '2113 N146WM 11:20');
  // Two planes from the same island: never a guess — no time, no plane, nothing to fill on the car.
  const u = by.get('PAT NOTSURE')!;
  assertEquals([u.arrival_time, u.registration, u.unsure, u.suggest_time, u.suggest_flight], ['', '', true, null, null]);
  assertEquals(u.route, 'COX-FXE 9:00 AM RV or COX-FXE 3:00 PM WM');
  // Counts per plane, not per number.
  const cnt = Object.fromEntries(w.inbound.map((f) => [`${f.flight} ${f.tail} ${f.time}`, f.pax]));
  assertEquals(cnt, { '27 N821DD 08:45': 1, '2113 N146WM 11:20': 1, '1534 N208JH 11:45': 1, '1534 N208JH 17:00': 1, '27 N624JR 17:30': 2 });
});

Deno.test('the wrong 8:45 reading of 11/21 → next reading moves the guest to 5:30 PM and fixes the car; unsure never writes', async () => {
  const w = await runWatch(suite, { date: '2026-11-21', pool: POOL, feedback: [] });
  const prev = [
    { passenger_id: 2, ticket: 'T2', system_name: 'ALEX HUBBARD', flight_number: '27', arrival_time: '08:45', registration: 'N821DD', kind: 'exact', state: 'ok' },
    { passenger_id: 5, ticket: 'T5', system_name: 'JON CHESTER', flight_number: '1534', arrival_time: '11:45', registration: 'N208JH', kind: 'exact', state: 'ok' },
    { passenger_id: 6, ticket: 'T6', system_name: 'PAT NOTSURE', flight_number: '777', arrival_time: '09:00', registration: 'N740RV', kind: 'exact', state: 'ok' },
  ];
  const mv = diffMoves(prev, w.match.matches.filter((m) => [2, 5, 6].includes(m.passenger_id)), new Set([2, 5, 6]));
  const x = (id: number) => mv.find((m) => m.passenger_id === id)!;
  assertEquals([x(2).what, x(2).time, x(2).registration], ['moved', '17:30', 'N624JR']);
  assertEquals(carUpdate(x(2), { departure_time: '08:45', return_flight: 'DD' }), { departure_time: '17:30', return_flight: 'JR' });
  assertEquals([x(5).what, x(5).time], ['moved', '17:00']);
  assertEquals(carUpdate(x(5), { departure_time: '11:45', return_flight: 'JH' }), { departure_time: '17:00' });
  assertEquals(x(6).what, 'unsure');
  assertEquals(carUpdate(x(6), { departure_time: '09:00', return_flight: 'RV' }), null);
  assertEquals(moveLine(x(6)), "PAT NOTSURE (#T6): flight 777 lands twice today (COX-FXE 9:00 AM RV or COX-FXE 3:00 PM WM). Makers' list does not say which one — check in Makers before getting the car ready.");
  // Same unsure reading again: no second alert. Then Makers puts him on one plane: "now on".
  const again = diffMoves(seenOf(w.match.matches), w.match.matches, new Set([6]));
  assertEquals(again.filter((m) => m.passenger_id === 6), []);
  const later = w.match.matches.map((m) => m.passenger_id === 6 ? { ...m, unsure: undefined, arrival_time: '15:00', registration: 'N146WM' } : m);
  const on = diffMoves(seenOf(w.match.matches), later, new Set([6])).find((m) => m.passenger_id === 6)!;
  assertEquals([on.what, on.time], ['on', '15:00']);
});

Deno.test('legFor: one plane → it; route decides; departures by destination; nothing in the schedule → undefined', () => {
  assertEquals(legFor(LEGS, p('2113', 'ASD', 'FXE', 'X', 'Y'), 'in')?.tail, 'N146WM');
  assertEquals(legFor(LEGS, p('777', 'COX', 'FXE', 'X', 'Y'), 'in'), null);
  assertEquals(legFor(LEGS, p('999', 'COX', 'FXE', 'X', 'Y'), 'in'), undefined);
  assertEquals(legFor(LEGS, p('26', 'FXE', 'GHC', 'X', 'Y'), 'out')?.tail, 'N624JR');
  assertEquals(legFor(LEGS, p('26', 'FXE', 'COX', 'X', 'Y'), 'out')?.tail, 'N821DD');
});

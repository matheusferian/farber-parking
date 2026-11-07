// deno test supabase/functions/_shared/makers/  — synthetic names only.
import { assertEquals } from 'jsr:@std/assert@1';
import { HeldCar, isAscendFlight, pickTrip, runSync, SuiteLike } from './sync.ts';
import type { Leg, PaxRow, Trip } from './suite.ts';

const LEGS: Leg[] = [
  { date: '11/07/2026', dep: '06:45', arr: '07:40', flight: '123', from: 'FXE', to: 'RSD', tail: 'N146WM' },
  { date: '11/07/2026', dep: '07:55', arr: '08:30', flight: '123', from: 'RSD', to: 'TYM', tail: 'N146WM' },
  { date: '11/07/2026', dep: '09:30', arr: '11:21', flight: '2407', from: 'COX', to: 'FXE', tail: 'N208JH' },
  { date: '11/07/2026', dep: '16:15', arr: '17:41', flight: '954', from: 'ELH', to: 'FXE', tail: 'N740RV' },
  { date: '11/07/2026', dep: '08:00', arr: '09:00', flight: '2404', from: 'FXE', to: 'COX', tail: 'N208JH' },
  { date: '11/07/2026', dep: '12:45', arr: '13:30', flight: '516', from: 'FXE', to: 'COX', tail: 'N146WM' },
];
const IN: PaxRow[] = [
  { date: '11/7/2026', flight: '2407', from: 'COX', to: 'FXE', last: 'GRASSETT', first: 'DAVID', retDate: '' },
  { date: '11/7/2026', flight: '2407', from: 'COX', to: 'FXE', last: 'STRANGER', first: 'ANN', retDate: '' },
  { date: '11/7/2026', flight: '954', from: 'ELH', to: 'FXE', last: 'DEEGAN', first: 'DOUG', retDate: '' },
];
const OUT: PaxRow[] = [
  { date: '11/7/2026', flight: '123', from: 'FXE', to: 'RSD', last: 'R1', first: 'A', retDate: '11/7/2026' },
  { date: '11/7/2026', flight: '123', from: 'FXE', to: 'TYM', last: 'T1', first: 'A', retDate: '11/9/2026' },
  { date: '11/7/2026', flight: '123', from: 'FXE', to: 'TYM', last: 'T2', first: 'B', retDate: '' },
  { date: '11/7/2026', flight: '2404', from: 'FXE', to: 'COX', last: 'A', first: 'B', retDate: '' },
  { date: '11/7/2026', flight: '2404', from: 'FXE', to: 'COX', last: 'A', first: 'B', retDate: '' },   // same person twice (round trip)
  { date: '11/7/2026', flight: '2404', from: 'FXE', to: 'COX', last: 'C', first: 'D', retDate: '' },
];
const TRIPS: Record<string, Trip[]> = {
  DOCTOR: [{ last: 'DOCTOR', first: 'RANDALL', dep: '2026-11-01', depTime: '12:45', ret: '2026-11-13', retTime: '16:15' }],
  GILL: [{ last: 'GILL', first: 'RICHARD', dep: '2026-11-01', depTime: '12:45', ret: '2026-11-09', retTime: '08:15' }],
  OPEN: [{ last: 'OPEN', first: 'PAT', dep: '2026-11-02', depTime: '12:45', ret: '', retTime: '' }],
  OLD: [{ last: 'OLD', first: 'SAM', dep: '2025-11-02', depTime: '12:45', ret: '2025-11-09', retTime: '10:00' }],
};
function fake(calls: string[]): SuiteLike {
  return {
    schedule: async (mdy) => { calls.push('schedule ' + mdy); return mdy === '11/7/2026' ? LEGS : []; },
    passengers: async (mdy, d) => { calls.push(`pax ${mdy} ${d.to ? 'to' : 'from'}`); return mdy !== '11/7/2026' ? [] : d.to ? IN : OUT; },
    trips: async (last) => { calls.push('trips ' + last); return TRIPS[last] || []; },
  };
}
const car = (id: number, name: string, ret: string | null, extra: Partial<HeldCar> = {}): HeldCar =>
  ({ id, ticket: 'T' + id, name, ret, status: 'PENDING', return_flight: null, departure_time: null, return_operator: 'MAKERS', checkin: '2026-11-01', ...extra });

Deno.test('evening run: tomorrow match + Makers return dates + departures', async () => {
  const calls: string[] = [];
  const r = await runSync(fake(calls), {
    date: '2026-11-07', today: '2026-11-06', feedback: [],
    pool: [
      car(1, 'DAVID GRASSET', '11/7/2026', { checkin: '2026-10-31' }),   // on tomorrow's flight (typo)
      car(2, 'RANDALL DOCTOR', '11/7/2026'),                              // Makers says 11/13
      car(3, 'RICHARD GILL', '11/9/2026'),                                // same date: nothing
      car(4, 'PAT OPEN', '11/20/2026', { checkin: '2026-11-02' }),        // no return booked in Makers
      car(5, 'SAM OLD', '11/9/2026', { checkin: '2026-11-02' }),          // only an old trip: not found
      car(6, 'ASC GUEST', '11/7/2026', { return_operator: 'ASCEND' }),   // Ascend: never looked up
    ],
  });
  assertEquals(r.inbound.map((f) => `${f.flight} ${f.route} ${f.time} ${f.pax}`), ['2407 COX-FXE 11:21 2', '954 ELH-FXE 17:41 1']);
  assertEquals(r.inbound.map((f) => f.dep), ['09:30', '16:15']); // island departure, for ON THE WAY on the TV
  assertEquals(r.outbound.map((f) => `${f.flight} ${f.time} ${f.pax}`), ['123 06:45 3', '2404 08:00 2']);
  assertEquals(r.outbound[0].day_trips, 0);   // R1: return date the same day but on no flight back to FXE → not a day trip (owner 11/07)
  const g = r.match.matches.find((m) => m.passenger_id === 1)!;
  assertEquals([g.state, g.suggest_flight, g.suggest_time, g.suggest_name], ['ok', 'JH', '11:21', 'DAVID GRASSETT']);
  assertEquals(r.match.missing.map((m) => m.passenger_id).sort(), [2, 6]);
  assertEquals(r.date_diffs, [{ passenger_id: 2, ticket: 'T2', system_name: 'RANDALL DOCTOR', ours: '11/7/2026', makers: '2026-11-13' }]);
  assertEquals(r.no_return.map((x) => x.passenger_id), [4]);
  assertEquals(r.not_found, 1);
  assertEquals(r.not_found_list.map((x) => x.passenger_id), [5]);
  assertEquals(calls.includes('trips GRASSET'), false);   // already settled by tomorrow's flight
  assertEquals(calls.includes('trips GUEST'), false);     // Ascend
  assertEquals(calls.filter((c) => c.startsWith('schedule')).length, 1);   // no tail/time lookups for later days
});

Deno.test('pickTrip: the trip around our check-in, never a surname-only match', () => {
  const trips: Trip[] = [
    { last: 'SMITH', first: 'JOHN', dep: '2025-11-01', depTime: '', ret: '2025-11-08', retTime: '' },
    { last: 'SMITH', first: 'JOHN', dep: '2026-11-01', depTime: '', ret: '2026-11-08', retTime: '' },
    { last: 'SMITH', first: 'MARY', dep: '2026-11-01', depTime: '', ret: '2026-11-05', retTime: '' },
  ];
  assertEquals(pickTrip(car(1, 'JON SMITH', null, { checkin: '2026-10-31' }), trips, '2026-11-06')?.ret, '2026-11-08');
  assertEquals(pickTrip(car(1, 'PAUL SMITH', null), trips, '2026-11-06'), null);
});

Deno.test('Ascend flights are the 99xx numbers', () => {
  assertEquals([isAscendFlight('9948'), isAscendFlight('9949'), isAscendFlight('9218'), isAscendFlight('881'), isAscendFlight('99')], [true, true, false, false, false]);
});

Deno.test('Return Date Follow-Up guest (NO DATE) flying out of FXE that day is reported', async () => {
  const suite = {
    schedule: async () => [{ date: '11/07/2026', dep: '06:45', arr: '07:30', flight: '881', from: 'FXE', to: 'ASD', tail: 'N310CH' }],
    passengers: async (_d: string, dir: { to?: string; from?: string }) => dir.from === 'FXE'
      ? [{ date: '11/7/2026', flight: '881', from: 'FXE', to: 'ASD', last: 'FRITTS', first: 'LUCY', retDate: '' }] : [],
    trips: async () => [],
  };
  const pool = [{ id: 900, ticket: '0812-15', name: 'LUCY FRITTS', ret: null, status: 'NO DATE', return_flight: null, departure_time: null, return_operator: 'MAKERS' }];
  // deno-lint-ignore no-explicit-any
  const r = await runSync(suite as any, { date: '2026-11-07', today: '2026-11-06', pool: pool as any, feedback: [] });
  assertEquals(r.followup_seen.map((f) => `${f.system_name} ${f.direction} ${f.flight} ${f.route} ${f.time}`), ['LUCY FRITTS out 881 FXE-ASD 06:45']);
});

Deno.test('check-in name list: everyone leaving FXE, first + last, once per flight, with time and destination', async () => {
  const suite = {
    schedule: async () => [{ date: '11/07/2026', dep: '08:00', arr: '09:00', flight: '2404', from: 'FXE', to: 'COX', tail: 'N208JH' }],
    passengers: async (_d: string, dir: { to?: string; from?: string }) => dir.from === 'FXE'
      ? [{ date: '11/7/2026', flight: '2404', from: 'FXE', to: 'COX', last: 'Augusto', first: 'Pedro', retDate: '' },
         { date: '11/7/2026', flight: '2404', from: 'FXE', to: 'COX', last: 'AUGUSTO', first: 'PEDRO', retDate: '' },
         { date: '11/7/2026', flight: '2404', from: 'FXE', to: 'COX', last: "O'Neil", first: 'Mary Ann', retDate: '' }] : [],
    trips: async () => [],
  };
  const r = await runSync(suite, { date: '2026-11-07', today: '2026-11-06', pool: [], feedback: [] });
  assertEquals(r.names, [{ name: 'PEDRO AUGUSTO', flight: '2404', time: '08:00', dest: 'COX' }, { name: "MARY ANN O'NEIL", flight: '2404', time: '08:00', dest: 'COX' }]);
});

Deno.test('pets are not passengers (owner 2026-11-07: dog, cat, bird, parrot, parakeet…)', async () => {
  const { isPetRow } = await import('./sync.ts');
  for (const r of [{ last: 'PET', first: 'ADAMS' }, { last: 'PET', first: 'DOG DUBOWITZ' }, { last: 'PET', first: 'DOGV KANTOR' }, { last: 'Pet', first: 'peel' },
    { last: 'DUBOWITZ', first: 'DOG' }, { last: 'SMITH', first: 'PARROT' }, { last: 'CAT', first: 'MILO' }, { last: 'PARAKEET', first: 'KIWI' }]) {
    if (!isPetRow(r)) throw new Error('should be a pet: ' + JSON.stringify(r));
  }
  for (const r of [{ last: 'PETERSON', first: 'ANNA' }, { last: 'ADAMS', first: 'PETER' }, { last: 'CATTANEO', first: 'LUCA' }, { last: 'BIRDSALL', first: 'JOHN' }, { last: 'DOGGETT', first: 'SAM' }, { last: 'PEEL', first: 'NANCY' }]) {
    if (isPetRow(r)) throw new Error('should be a person: ' + JSON.stringify(r));
  }
});

Deno.test('day trip only when also booked on a flight back to FXE the same day (owner 2026-11-07)', async () => {
  const back: PaxRow = { date: '11/7/2026', flight: '954', from: 'ELH', to: 'FXE', last: 'R1', first: 'A', retDate: '' };
  const suite: SuiteLike = {
    schedule: async (mdy) => mdy === '11/7/2026' ? LEGS : [],
    passengers: async (mdy, d) => mdy !== '11/7/2026' ? [] : d.to ? [...IN, back] : OUT,
    trips: async () => [],
  };
  const r = await runSync(suite, { date: '2026-11-07', today: '2026-11-06', feedback: [], pool: [] });
  assertEquals(r.outbound[0].day_trips, 1);
});

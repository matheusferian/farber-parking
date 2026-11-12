// deno test supabase/functions/_shared/makers/  — synthetic names only.
import { assertEquals } from 'jsr:@std/assert@1';
import type { Match } from '../manifest/match.ts';
import { carUpdate, diffMoves, moveLine, seenOf } from './moves.ts';
import { runWatch, type SuiteLike } from './sync.ts';
import type { Leg, PaxRow } from './suite.ts';

const mk = (id: number, name: string, flight: string, time: string, reg: string, o: Partial<Match> = {}): Match => ({
  passenger_id: id, ticket: `1110-${id}`, system_name: name, manifest_name: name, kind: 'exact', score: 1, state: 'ok', ret: '11/12/2026',
  manifest_date: '2026-11-12', operator: 'MAKERS', flight_number: flight, route: 'GHC-FXE', registration: reg, arrival_time: time, day_trip: false,
  ascend: false, suggest_name: null, suggest_flight: null, suggest_time: null, current_flight: '', current_time: '', ...o,
});

// Owner 2026-11-12: DAVID HOCHER was on the 11:00 (flight 1534, RV) at 6 AM, then moved to the 5 PM flight.
Deno.test('flight changed: later flight, earlier flight, off every flight, newly on a flight', () => {
  const prev = seenOf([
    mk(1, 'DAVID HOCHER', '1534', '11:00', 'N740RV'),
    mk(2, 'ANN EARLY', '1540', '17:00', 'N146WM'),
    mk(3, 'BOB GONE', '1534', '11:00', 'N740RV'),
    mk(4, 'CAROL SAME', '1534', '11:00', 'N740RV'),
    mk(5, 'DAN PICKED', '1534', '11:00', 'N740RV'),                       // car delivered since → not "off"
    mk(6, 'EVE FAMILY', '1534', '11:00', 'N740RV', { kind: 'surname_only' }),
  ]);
  const cur = [
    mk(1, 'DAVID HOCHER', '1538', '17:00', 'N146WM'),
    mk(2, 'ANN EARLY', '1534', '11:00', 'N740RV'),
    mk(4, 'CAROL SAME', '1534', '11:00', 'N740RV'),
    mk(6, 'EVE FAMILY', '1534', '11:00', 'N740RV'),                       // was surname-only, now confirmed: not "new"
    mk(7, 'FRED NEW', '1534', '11:00', 'N740RV', { state: 'early' }),
    mk(8, 'GUS SURNAME', '1534', '11:00', 'N740RV', { kind: 'surname_only' }),
  ];
  const held = new Set([1, 2, 3, 4, 6, 7, 8]);
  const mv = diffMoves(prev, cur, held);
  assertEquals(mv.map((x) => [x.system_name, x.what]), [
    ['ANN EARLY', 'moved'], ['BOB GONE', 'off'], ['FRED NEW', 'on'], ['DAVID HOCHER', 'moved'],
  ]);
  const line = (n: string) => moveLine(mv.find((x) => x.system_name === n)!);
  assertEquals(line('DAVID HOCHER'), "DAVID HOCHER (#1110-1): was 11:00 AM (flight 1534), now 5:00 PM (flight 1538). Don't get the car ready yet.");
  assertEquals(line('ANN EARLY'), 'ANN EARLY (#1110-2): was 5:00 PM (flight 1540), now 11:00 AM (flight 1534). Get the car ready sooner.');
  assertEquals(line('BOB GONE'), 'BOB GONE (#1110-3): no longer on flight 1534 11:00 AM. Check with Makers before waiting.');
  assertEquals(line('FRED NEW'), 'FRED NEW (#1110-7): now on flight 1534 landing 11:00 AM — earlier than our return date.');
  // a no-show already reported by the no-show alert is not reported twice
  assertEquals(diffMoves(prev, cur, held, new Set([3])).some((x) => x.system_name === 'BOB GONE'), false);
  // nothing changed → nothing to say
  assertEquals(diffMoves(prev, [mk(4, 'CAROL SAME', '1534', '11:0', 'N740RV')].map((m) => ({ ...m, arrival_time: '11:00' })), new Set([4])), []);
});

Deno.test('car time follows the new flight only while it still shows the old one', () => {
  const [x] = diffMoves(seenOf([mk(1, 'DAVID HOCHER', '1534', '11:00', 'N740RV')]), [mk(1, 'DAVID HOCHER', '1538', '17:00', 'N146WM')], new Set([1]));
  assertEquals(carUpdate(x, { departure_time: '11:00', return_flight: 'RV' }), { departure_time: '17:00', return_flight: 'WM' });
  assertEquals(carUpdate(x, { departure_time: '11:00', return_flight: '' }), { departure_time: '17:00' });            // tail left for staff
  assertEquals(carUpdate(x, { departure_time: '11:00', return_flight: 'JR' }), { departure_time: '17:00' });          // tail typed by hand stays
  assertEquals(carUpdate(x, { departure_time: '12:30', return_flight: 'RV' }), null);                                 // time typed by hand stays
  assertEquals(carUpdate(x, { departure_time: '', return_flight: '' }), null);                                       // empty: staff fill it
  assertEquals(carUpdate({ ...x, state: 'early' }, { departure_time: '11:00', return_flight: 'RV' }), null);          // other day: staff decide
  assertEquals(carUpdate({ ...x, what: 'off' }, { departure_time: '11:00', return_flight: 'RV' }), null);
});

Deno.test('quick check: only today\'s arrivals at FXE (2 searches), pets out, same matcher', async () => {
  const legs: Leg[] = [{ date: '11/12/2026', dep: '16:00', arr: '17:00', flight: '1538', from: 'GHC', to: 'FXE', tail: 'N146WM' },
    { date: '11/12/2026', dep: '06:45', arr: '07:40', flight: '123', from: 'FXE', to: 'RSD', tail: 'N146WM' }];
  const pax: PaxRow[] = [{ date: '11/12/2026', flight: '1538', from: 'GHC', to: 'FXE', last: 'HOCHER', first: 'DAVID', retDate: '' },
    { date: '11/12/2026', flight: '1538', from: 'GHC', to: 'FXE', last: 'PET', first: 'HOCHER', retDate: '' }];
  const calls: string[] = [];
  const s: SuiteLike = {
    schedule: async (mdy) => { calls.push('schedule ' + mdy); return legs; },
    passengers: async (mdy, d) => { calls.push(`pax ${mdy} ${d.to ? 'to' : 'from'}`); return d.to ? pax : []; },
    trips: async () => { calls.push('trips'); return []; },
  };
  const w = await runWatch(s, { date: '2026-11-12', feedback: [], pool: [{ id: 1, ticket: '1110-8', name: 'DAVID HOCHER', ret: '11/12/2026', status: 'PENDING', departure_time: '11:00', return_flight: 'RV' }] });
  assertEquals(calls, ['schedule 11/12/2026', 'pax 11/12/2026 to']);
  assertEquals(w.inbound.map((f) => [f.flight, f.time, f.pax]), [['1538', '17:00', 1]]);
  assertEquals(w.match.matches.map((m) => [m.system_name, m.flight_number, m.arrival_time, m.registration]), [['DAVID HOCHER', '1538', '17:00', 'N146WM']]);
});

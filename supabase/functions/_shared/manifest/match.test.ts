// deno test supabase/functions/_shared/manifest/  — synthetic names only (no customer data in the repo).
import { assert, assertEquals } from 'jsr:@std/assert@1';
import { Candidate, flightValueFor, jaroWinkler, ManifestPage, matchManifest, normTokens, scoreName } from './match.ts';

const P = (last: string, first: string, middle = '', origin = 'GHC') => ({ last, first, middle, pnr: 'MT0000', first_origin: origin });
const page = (flight: string, tail: string, time: string, pax: ReturnType<typeof P>[], extra: Partial<ManifestPage> = {}): ManifestPage => ({
  flight_number: flight, manifest_date: '11/06/2026', route: 'GHC-FXE', tail_number: tail, arrival_time: time,
  total_pax: pax.length, ascend_mark: false, passengers: pax, ...extra,
});
const C = (id: number, name: string, ret: string | null, extra: Partial<Candidate> = {}): Candidate => ({
  id, ticket: `T-${id}`, name, ret, status: 'PENDING', return_flight: null, departure_time: null, return_operator: 'MAKERS', ...extra,
});

Deno.test('normTokens drops suffixes, accents, apostrophes; splits hyphens', () => {
  assertEquals(normTokens("Barry Flanigan Jr"), ['BARRY', 'FLANIGAN']);
  assertEquals(normTokens("DAVID O'CONNOR"), ['DAVID', 'OCONNOR']);
  assertEquals(normTokens('Daly - Carnell'), ['DALY', 'CARNELL']);
  assertEquals(normTokens('José Gonçalves III'), ['JOSE', 'GONCALVES']);
});

Deno.test('typos in our system still match, and the manifest spelling is suggested', () => {
  for (const ours of ['MATEUS FERREIRA', 'MATHEUW FERREIRA', 'MATHEUS FEREIRA', 'MATHEUS FERRIERA']) {
    const s = scoreName(ours, P('FERREIRA', 'MATHEUS'));
    assert(s && s.kind === 'typo', `${ours} → ${JSON.stringify(s)}`);
  }
  const r = matchManifest([page('100', 'N740RV', '11:00', [P('FERREIRA', 'MATHEUS')])], [C(1, 'MATEUS FERREIRA', '11/6/2026')], []);
  assertEquals(r.matches[0].suggest_name, 'MATHEUS FERREIRA');
});

Deno.test('exact names, suffix only differs → no correction offered', () => {
  const r = matchManifest([page('2113', 'N146WM', '11:01', [P('FLANIGAN JR', 'BARRY', 'SEAN')])], [C(1, 'BARRY FLANIGAN', '11/6/2026')], []);
  assertEquals(r.matches[0].kind, 'exact');
  assertEquals(r.matches[0].suggest_name, null);
});

Deno.test('nickname and middle name', () => {
  assertEquals(scoreName('MIKE ROWE', P('ROWE', 'MICHAEL'))?.kind, 'nickname');
  assert((scoreName('SEAN FLANIGAN', P('FLANIGAN', 'BARRY', 'SEAN'))?.score ?? 0) > 0.9);
});

Deno.test('a different person with the same surname is only "surname_only", never typo', () => {
  assertEquals(scoreName('SHANNON WOODWARD', P('WOODWARD', 'THOMAS'))?.kind, 'surname_only');
  assertEquals(scoreName('PAUL SMITH', P('JONES', 'PAUL')), null);
});

Deno.test('family on one flight: each passenger gets the right row', () => {
  const pg = page('2113', 'N146WM', '11:01', [P('WOODWARD', 'THOMAS'), P('WOODWARD', 'SHANNON', 'ADAMS')]);
  const r = matchManifest([pg], [C(1, 'SHANNON WOODWARD', '11/6/2026'), C(2, 'TOMMY WOODWARD', '11/6/2026')], []);
  const by = Object.fromEntries(r.matches.map((m) => [m.passenger_id, m.manifest_name]));
  assertEquals(by[1], 'SHANNON WOODWARD');
  assertEquals(by[2], 'THOMAS WOODWARD');
});

Deno.test('the 11/06 case: early return, ok, delivered, missing, tail + time suggestions', () => {
  const pages = [
    page('4687', 'N740RV', '11:00', [P('TAYLOR', 'ALEX', 'ALVIN'), P('PRICE', 'TOM', 'ANTHONY'), P('DURANT', 'MICHAEL')]),
    page('1534', 'N740RV', '17:00', [P('ENSTONE', 'ROBERTA', '', 'FXE'), P('ENSTONE', 'ELLA', 'MARION', 'FXE')], { route: 'TYM-FXE' }),
    page('9949', 'N310CH', '16:00', [P('ALTMAN', 'WILLIAM', 'JOSEPH', 'FXE'), P('ALTMAN', 'DANA', 'MARIE', 'FXE')], { ascend_mark: true }),
  ];
  const cands = [
    C(1, 'ALEX TAYLOR', '11/6/2026', { status: 'DELIVERED', deldate: '11/6/2026', return_flight: 'RV' }),
    C(2, 'TOM PRICE', '11/9/2026'),                                    // early return
    C(3, 'ELLA ENSTONE', '11/6/2026', { return_flight: 'RV' }),        // ok, flight already right
    C(4, 'WILLIAM ALTMAN', '11/6/2026', { return_operator: 'ASCEND' }),
    C(5, 'GRACE HOLT', '11/6/2026'),                                   // expected today, not on any list
    C(6, 'OLD GUEST', '11/6/2026', { status: 'DELIVERED', deldate: '11/1/2026' }),
  ];
  const r = matchManifest(pages, cands, []);
  const by = Object.fromEntries(r.matches.map((m) => [m.passenger_id, m]));
  assertEquals(r.manifest_date, '2026-11-06');
  assertEquals(by[2].state, 'early');
  assertEquals(by[2].suggest_flight, 'RV');
  assertEquals(by[2].suggest_time, '11:00');
  assertEquals(by[1].state, 'delivered');
  assertEquals(by[3].state, 'ok');
  assertEquals(by[3].suggest_flight, null);
  assertEquals(by[3].day_trip, true);
  assertEquals(by[4].ascend, true);
  assertEquals(by[4].suggest_flight, 'CH');
  assertEquals(r.missing.map((m) => m.passenger_id), [5]);
  assertEquals(by[6], undefined);
  assertEquals(r.matches[0].passenger_id, 2);                        // surprises first
});

Deno.test('staff feedback: "different" is never suggested again, "same" always matches', () => {
  const pg = [page('1', 'N740RV', '11:00', [P('SMYTHE', 'JOHN')])];
  assertEquals(matchManifest(pg, [C(1, 'JON SMITH', '11/6/2026')], [{ manifest_name: 'JOHN SMYTHE', system_name: 'JON SMITH', verdict: 'different' }]).matches.length, 0);
  const r = matchManifest(pg, [C(1, 'J R SMITH', '11/6/2026')], [{ manifest_name: 'JOHN SMYTHE', system_name: 'J R SMITH', verdict: 'same' }]);
  assertEquals(r.matches[0].kind, 'taught');
});

Deno.test('unknown registration is kept whole', () => {
  assertEquals(flightValueFor('N 740RV'), 'RV');
  assertEquals(flightValueFor('N999ZZ'), 'N999ZZ');
  assert(jaroWinkler('MATHEUS', 'MATEUS') > 0.9);
});

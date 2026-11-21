// Makers robot logic (owner 2026-11-06): what the evening run computes from Makers Air Suite.
//   • Tomorrow's arrivals at FXE matched with the cars we hold (early returns, guests with no flight,
//     tail + FXE arrival time to fill, name typos) — the same matcher as the manifest check.
//   • Every car we hold (Makers guests): the return date booked in Makers vs ours. A different date
//     comes back with the Makers date only. Tail and arrival time are filled ONLY the evening before
//     (owner: the aircraft can change until then), through the tomorrow match above.
//   • Tomorrow's departures from FXE (flights, times, passenger counts) and arrivals (counts).
// Times are always the arrival at FXE (owner: "o horário que chega aqui"), never the island departure.
// Pure orchestration over a SuiteLike reader, so it is tested without Makers.

import { Candidate, Feedback, ManifestPage, MatchResult, matchManifest, normTokens, parseDate, scoreName } from '../manifest/match.ts';
import type { Leg, PaxRow, Trip } from './suite.ts';
import { paxKey } from './changes.ts';

export type SuiteLike = {
  schedule(mdy: string): Promise<Leg[]>;
  passengers(mdy: string, dir: { to?: string; from?: string }): Promise<PaxRow[]>;
  trips(last: string, first?: string): Promise<Trip[]>;
  passengersByLast?(last: string, fromMdy: string, toMdy: string): Promise<PaxRow[]>;
};
export type HeldCar = Candidate & { checkin?: string | null };   // check-in day, YYYY-MM-DD
// time = FXE arrival (inbound) or FXE departure (outbound); dep = departure from the island (inbound only),
// used by the TV to show ON THE WAY before the aircraft is in radar range (owner 2026-11-06).
// ids (outbound only): anonymous passenger keys (changes.ts) to tell cancelled from moved between readings.
// dests (outbound only, owner 2026-11-12): where the people on board are going (Passenger Flight List "TO"),
// biggest first — route is only the first stop (e.g. FXE-SAQ, then on to Staniel Cay / Great Harbour).
export type FlightSummary = { flight: string; route: string; tail: string; time: string; pax: number; ascend: boolean; day_trips?: number; dep?: string; ids?: string[]; dests?: { to: string; pax: number }[] };
// Ascend (Makers' charter brand) flights are the 4-digit 9xxx numbers in Makers Air Suite: 9948/9949 (11/06-07),
// 9218/9219 and 9371 (owner 2026-11-12: the two 8:30 Great Harbour flights on 11/13 are Ascend; the old 99xx rule
// missed them). Regular Makers flights seen so far: 123-7524, incl. 3-digit 954 — never 4-digit 9xxx.
// The Suite reports carry no client name, so the number is the only sign.
export const isAscendFlight = (flight: string) => /^9\d{3}$/.test(String(flight || '').trim());
export type DateDiff = { passenger_id: number; ticket: string; system_name: string; ours: string | null; makers: string };
export type NoReturn = { passenger_id: number; ticket: string; system_name: string; ours: string | null };
export type NotFound = NoReturn;   // no Makers trip for this name around our check-in: staff look it up by hand
// A Return Date Follow-Up guest (status NO DATE) on a Makers flight from FXE that day (owner 2026-11-06).
export type FollowUpSeen = { passenger_id: number; ticket: string; system_name: string; direction: 'out' | 'in'; flight: string; route: string; time: string };
// Owner 2026-11-12: a same-last-name pair is checked in Makers BEFORE it is shown — when our guest flew out
// and comes back, when the other person flew out, and whether they were on the same flight.
export type Leg1 = { date: string; flight: string; route: string };
export type SurnameCheck = { car_out: Leg1 | null; car_back: Leg1 | null; other_out: Leg1 | null; other_back: Leg1 | null; together: boolean | null };
export type SyncResult = {
  date: string; inbound: FlightSummary[]; outbound: FlightSummary[]; match: MatchResult;
  date_diffs: DateDiff[]; no_return: NoReturn[]; not_found_list: NotFound[]; checked: number; not_found: number; warnings: string[];
  followup_seen: FollowUpSeen[];
  // Owner 2026-11-06: names (first + last only) of everyone leaving FXE that day, for the check-in name
  // suggestions. NEVER stored in the scan result: makers-sync writes them to airvalet_makers_names (one day).
  names: { name: string; flight: string; time: string; dest: string }[];
};

export const isoToMdy = (iso: string) => { const [y, m, d] = iso.split('-'); return `${+m}/${+d}/${y}`; };
const addDays = (iso: string, n: number) => { const d = new Date(iso + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };

// The Makers trip for this car: same person (first name may be a typo/nickname, never surname-only),
// departure around our check-in day; latest departure wins when we do not know the check-in.
export function pickTrip(car: HeldCar, trips: Trip[], today: string): Trip | null {
  const scored = trips.map((t) => ({ t, s: scoreName(car.name, { last: t.last, first: t.first, middle: '', pnr: '', first_origin: '' }) }))
    .filter((x) => x.s && x.s.kind !== 'surname_only' && x.t.dep);
  if (!scored.length) return null;
  const ci = car.checkin || null;
  const near = ci ? scored.filter((x) => Math.abs((Date.parse(x.t.dep) - Date.parse(ci)) / 864e5) <= 4) : scored.filter((x) => !x.t.ret || x.t.ret >= addDays(today, -1));
  if (!near.length) return null;
  near.sort((a, b) => (b.s!.score - a.s!.score) || (ci ? Math.abs(Date.parse(a.t.dep) - Date.parse(ci)) - Math.abs(Date.parse(b.t.dep) - Date.parse(ci)) : b.t.dep.localeCompare(a.t.dep)));
  return near[0].t;
}

// Owner 2026-11-07: Makers books a pet as a passenger with the surname "PET" ("PET, ADAMS", "PET, DOG DUBOWITZ").
// Any animal (dog, cat, bird, parrot, parakeet…) is not a person: never counted, never a name suggestion,
// never matched to a car.
const PET_WORD = /^(PETS?|ANIMALS?|DOGS?|PUPP(Y|IES)|K9|CANINE|CATS?|KITTEN|BIRDS?|PARROTS?|PARAKEETS?|BUDGIES?|COCKATIELS?|RABBITS?|BUNNY|FERRETS?|HAMSTERS?|TURTLES?)$/;
export function isPetRow(r: { last: string; first: string }): boolean {
  const last = String(r.last || '').trim().toUpperCase(), first = String(r.first || '').trim().toUpperCase();
  return PET_WORD.test(last) || PET_WORD.test(first) || PET_WORD.test(first.split(/\s+/)[0] || '');
}

const mdyToIso = (mdy: string) => { const m = /^(\d{1,2})\/(\d{1,2})\/(\d{4})$/.exec(mdy || ''); return m ? `${m[3]}-${m[1].padStart(2, '0')}-${m[2].padStart(2, '0')}` : ''; };
const samePerson = (name: string, r: PaxRow) => { const s = scoreName(name, { last: r.last, first: r.first, middle: '', pnr: '', first_origin: '' }); return !!s && s.kind !== 'surname_only'; };
// Owner 2026-11-20 (RODERICK CIFERRI 1120-3): Makers' last-name search is exact — "CIFERRI" finds nothing when
// the booking says "CIFERRI III". With no row for the plain surname, the same search is tried with the usual
// suffixes (read-only, at most 5 more searches; `budget` caps them per robot run).
export const LAST_SUFFIXES = ['JR', 'III', 'II', 'SR', 'IV'];
export async function byLastAnySuffix(suite: SuiteLike, last: string, fromMdy: string, toMdy: string, budget?: { n: number }): Promise<PaxRow[]> {
  const rows = await suite.passengersByLast!(last, fromMdy, toMdy);
  if (rows.some((r) => !isPetRow(r))) return rows;
  for (const suf of LAST_SUFFIXES) {
    if (budget) { if (budget.n <= 0) break; budget.n--; }
    const more = await suite.passengersByLast!(`${last} ${suf}`, fromMdy, toMdy);
    if (more.some((r) => !isPetRow(r))) return more;
  }
  return rows;
}
const leg1 = (r: PaxRow): Leg1 => ({ date: mdyToIso(r.date), flight: r.flight, route: `${r.from}-${r.to}` });

// Our guest: the flight out of FXE nearest our check-in day (±4 days), then the first flight back to FXE after it.
// The other person: the last flight out of FXE before the manifest day, and the flight back to FXE on that day.
export async function surnameCheck(suite: SuiteLike, car: HeldCar | undefined, systemName: string, manifestName: string, date: string): Promise<SurnameCheck> {
  const last = normTokens(manifestName).pop() || '';
  const ci = car?.checkin || null, ours = car ? parseDate(car.ret) : '';
  const from = addDays([ci, date].filter(Boolean).sort()[0] as string, -45), to = addDays([ours, date].filter(Boolean).sort().reverse()[0] as string, 7);
  const rows = (await suite.passengersByLast!(last, isoToMdy(from), isoToMdy(to))).filter((r) => !isPetRow(r) && mdyToIso(r.date));
  const byDate = (a: PaxRow, b: PaxRow) => mdyToIso(a.date).localeCompare(mdyToIso(b.date));
  const mine = rows.filter((r) => samePerson(systemName, r)).sort(byDate), theirs = rows.filter((r) => samePerson(manifestName, r)).sort(byDate);
  const outs = mine.filter((r) => r.from === 'FXE' && (!ci || Math.abs((Date.parse(mdyToIso(r.date)) - Date.parse(ci)) / 864e5) <= 4));
  const carOut = ci ? outs.sort((a, b) => Math.abs(Date.parse(mdyToIso(a.date)) - Date.parse(ci)) - Math.abs(Date.parse(mdyToIso(b.date)) - Date.parse(ci)))[0] : outs.pop();
  const carBack = carOut ? mine.find((r) => r.to === 'FXE' && mdyToIso(r.date) > mdyToIso(carOut.date)) : undefined;
  const otherOut = theirs.filter((r) => r.from === 'FXE' && mdyToIso(r.date) <= date).pop();
  const otherBack = theirs.find((r) => r.to === 'FXE' && mdyToIso(r.date) === date);
  return { car_out: carOut ? leg1(carOut) : null, car_back: carBack ? leg1(carBack) : null, other_out: otherOut ? leg1(otherOut) : null,
    other_back: otherBack ? leg1(otherBack) : null,
    together: carOut && otherOut ? (carOut.date === otherOut.date && carOut.flight === otherOut.flight) : null };
}

// Owner 2026-11-12: View Reservation returns only 50 reservations, oldest first, so a common last name
// (ADAMS) came back "not found". Second try: the Passenger Flight List searched by last name (no row limit).
// Same rules as pickTrip: our guest's flight out of FXE nearest the check-in day (±4), else the latest one
// still away; the return date is the booked Return Date, else the next flight of that person back to FXE.
export function tripFromFlights(car: HeldCar, rows: PaxRow[], today: string): Trip | null {
  const mine = rows.filter((r) => !isPetRow(r) && mdyToIso(r.date) && samePerson(car.name, r))
    .sort((a, b) => mdyToIso(a.date).localeCompare(mdyToIso(b.date)));
  const ci = car.checkin || null;
  const outs = mine.filter((r) => r.from === 'FXE');
  // A Return Date equal to the departure day is not trusted (Makers shows it on bookings with no return yet):
  // then the person's next flight back to FXE decides.
  const retOf = (o: PaxRow) => {
    const rd = mdyToIso(o.retDate), dep = mdyToIso(o.date);
    if (rd && rd !== dep) return rd;
    return mdyToIso(mine.find((r) => r.to === 'FXE' && mdyToIso(r.date) >= dep && r !== o)?.date || '');
  };
  const out = ci
    ? outs.filter((r) => Math.abs((Date.parse(mdyToIso(r.date)) - Date.parse(ci)) / 864e5) <= 4)
      .sort((a, b) => Math.abs(Date.parse(mdyToIso(a.date)) - Date.parse(ci)) - Math.abs(Date.parse(mdyToIso(b.date)) - Date.parse(ci))
        || retOf(b).localeCompare(retOf(a)))[0]   // same day, two bookings: the one with the real return
    : outs.filter((r) => mdyToIso(r.date) <= today && (!retOf(r) || retOf(r) >= addDays(today, -1))).pop();
  if (!out) return null;
  return { last: out.last, first: out.first, dep: mdyToIso(out.date), depTime: '', ret: retOf(out), retTime: '' };
}

// Owner 2026-11-21 (AUSTIN HUEBNER 1120-7, JOHN CHEESBOROUGH 1117-9 — "não admito mais esse tipo de erro"):
// Makers reuses one flight number for two planes the same day (27: DD COX→FXE 8:45 AM and JR GHC→FXE 5:30 PM;
// 1534: JH GHC→FXE 11:45 AM and JH TYM→FXE 5:00 PM). The Passenger Flight List only says "flight 27", and the
// robot used to put everyone on the first one: a car was brought out for nothing. Now a passenger goes to a leg
// only when it is the ONLY leg with that number, or the only one whose route serves the passenger's From (arrivals)
// / TO (departures) — the same plane's earlier (arrivals) or later (departures) legs under that number count, for a
// stop on the way. Otherwise the answer is null = UNSURE: no time and no plane are given (never a guess).
// undefined = no leg with that number in the schedule.
export function legFor(L: Leg[], r: PaxRow, dir: 'in' | 'out'): Leg | null | undefined {
  const cands = L.filter((l) => l.flight === r.flight && (dir === 'in' ? l.to === 'FXE' : l.from === 'FXE'));
  if (cands.length <= 1) return cands[0];
  // Walk the same plane's connected legs under that number (stops on the way), never past FXE.
  const serves = (l: Leg) => {
    const pts = new Set<string>();
    let cur: Leg | undefined = l;
    for (let i = 0; cur && i < 6; i++) {
      const c: Leg = cur;
      pts.add(dir === 'in' ? c.from : c.to);
      cur = L.find((x) => x !== c && x.flight === c.flight && x.tail === c.tail && (dir === 'in'
        ? x.to === c.from && x.to !== 'FXE' && x.from !== 'FXE' && !!x.arr && x.arr <= c.dep
        : x.from === c.to && x.from !== 'FXE' && x.to !== 'FXE' && !!x.dep && x.dep >= c.arr));
    }
    return pts.has(dir === 'in' ? r.from : r.to);
  };
  const hit = cands.filter(serves);
  return hit.length === 1 ? hit[0] : null;
}
const legKey = (l: Leg) => `${l.flight}|${l.tail}|${l.dep}|${l.arr}|${l.from}|${l.to}`;

// Flights landing at FXE that day with people on board (same person counted once), earliest first.
export function inboundOf(L: Leg[], inPax: PaxRow[]): FlightSummary[] {
  const per = new Map<string, Set<string>>();
  for (const r of inPax) {
    const l = legFor(L, r, 'in'); if (!l) continue;
    const k = legKey(l); if (!per.has(k)) per.set(k, new Set()); per.get(k)!.add(`${r.last}|${r.first}`);
  }
  return L.filter((l) => l.to === 'FXE').map((l) => ({ flight: l.flight, route: `${l.from}-FXE`, tail: l.tail, time: l.arr, dep: l.dep, pax: per.get(legKey(l))?.size || 0, ascend: isAscendFlight(l.flight) }))
    .filter((f) => f.pax > 0).sort((a, b) => a.time.localeCompare(b.time));
}
const t12s = (t: string) => { const m = /^(\d{1,2}):(\d{2})/.exec(t || ''); if (!m) return t || ''; const h = +m[1]; return `${h % 12 || 12}:${m[2]} ${h < 12 ? 'AM' : 'PM'}`; };
export function pagesOf(inbound: FlightSummary[], inPax: PaxRow[], date: string, L: Leg[] = []): ManifestPage[] {
  const md = isoToMdy(date).split('/').map((x, i) => i < 2 ? x.padStart(2, '0') : x).join('/');
  const once = (rows: PaxRow[]) => rows.filter((r, i, all) => all.findIndex((x) => x.last === r.last && x.first === r.first) === i)
    .map((r) => ({ last: r.last, first: r.first, middle: '', pnr: '', first_origin: r.from }));
  const pages: ManifestPage[] = inbound.map((f) => {
    const leg = L.find((l) => l.to === 'FXE' && l.flight === f.flight && l.tail === f.tail && l.arr === f.time && `${l.from}-FXE` === f.route);
    const rows = leg ? inPax.filter((r) => legFor(L, r, 'in') === leg) : inPax.filter((r) => r.flight === f.flight);
    return { flight_number: f.flight, manifest_date: md, route: f.route, tail_number: f.tail, arrival_time: f.time, total_pax: f.pax, ascend_mark: f.ascend, passengers: once(rows) };
  });
  // UNSURE: same flight number on two planes and the passenger's From does not say which → a page with NO time
  // and NO plane (the match carries unsure: true; nothing is filled on the car; staff check in Makers).
  const unsure = new Map<string, PaxRow[]>();
  if (L.length) for (const r of inPax) if (legFor(L, r, 'in') === null) { if (!unsure.has(r.flight)) unsure.set(r.flight, []); unsure.get(r.flight)!.push(r); }
  for (const [flight, rows] of unsure) {
    const legs = L.filter((l) => l.flight === flight && l.to === 'FXE').sort((a, b) => a.arr.localeCompare(b.arr));
    pages.push({ flight_number: flight, manifest_date: md, route: legs.map((l) => `${l.from}-FXE ${t12s(l.arr)} ${l.tail.slice(-2)}`).join(' or '),
      tail_number: '', arrival_time: '', total_pax: once(rows).length, ascend_mark: isAscendFlight(flight), unsure: true, passengers: once(rows) });
  }
  return pages;
}

// Owner 2026-11-12 (DAVID HOCHER moved from the 11:00 to a 5 PM flight after the 6 AM reading): the quick
// check every 30 minutes — only that day's flights landing at FXE and their people, matched with our cars.
// 2 Makers searches, read-only.
export async function runWatch(suite: SuiteLike, o: { date: string; pool: HeldCar[]; feedback: Feedback[] }): Promise<{ inbound: FlightSummary[]; match: MatchResult }> {
  const L = await suite.schedule(isoToMdy(o.date));
  const inPax = (await suite.passengers(isoToMdy(o.date), { to: 'FXE' })).filter((r) => !isPetRow(r));
  const inbound = inboundOf(L, inPax);
  return { inbound, match: matchManifest(pagesOf(inbound, inPax, o.date, L), o.pool, o.feedback) };
}

export async function runSync(suite: SuiteLike, o: { date: string; today: string; pool: HeldCar[]; feedback: Feedback[]; maxLookups?: number; keySecret?: string }): Promise<SyncResult> {
  const warnings: string[] = [];
  const legsByDay = new Map<string, Leg[]>(), inByDay = new Map<string, PaxRow[]>();
  const legs = async (iso: string) => { if (!legsByDay.has(iso)) legsByDay.set(iso, await suite.schedule(isoToMdy(iso))); return legsByDay.get(iso)!; };
  const humans = (rows: PaxRow[]) => rows.filter((r) => !isPetRow(r));
  const arrivals = async (iso: string) => { if (!inByDay.has(iso)) inByDay.set(iso, humans(await suite.passengers(isoToMdy(iso), { to: 'FXE' }))); return inByDay.get(iso)!; };

  // 1. Tomorrow: arrivals and departures.
  const L = await legs(o.date), inPax = await arrivals(o.date), outPax = humans(await suite.passengers(isoToMdy(o.date), { from: 'FXE' }));
  // The report can list the same person twice (both legs of one booking): count each name once.
  const inbound = inboundOf(L, inPax);
  // Departures: one line per flight (owner: destination only, no stops). Each passenger is counted once;
  // a return booked the same day is a day trip.
  const sameDay = (d: string) => { const m = d.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/); return !!m && `${m[3]}-${m[1].padStart(2, '0')}-${m[2].padStart(2, '0')}` === o.date; };
  const backToday = new Set(inPax.map((r) => `${r.last}|${r.first}`));
  const outbound: FlightSummary[] = L.filter((l) => l.from === 'FXE').map((l) => {
    const people = new Map<string, PaxRow>();
    for (const r of outPax) if (r.flight === l.flight && legFor(L, r, 'out') === l) people.set(`${r.last}|${r.first}`, r);
    const byDest = new Map<string, number>();
    for (const r of people.values()) if (r.to) byDest.set(r.to, (byDest.get(r.to) || 0) + 1);
    const dests = [...byDest].map(([to, pax]) => ({ to, pax })).sort((a, b) => b.pax - a.pax || a.to.localeCompare(b.to));
    return { flight: l.flight, route: `FXE-${l.to}`, tail: l.tail, time: l.dep, pax: people.size, ascend: isAscendFlight(l.flight), dests,
      // Owner 2026-11-07: a day trip only when Makers shows the return the SAME day AND the person is booked on a
      // flight back to FXE that day (the passenger list to FXE) — the return date alone is not enough.
      day_trips: [...people.values()].filter((r) => sameDay(r.retDate) && backToday.has(`${r.last}|${r.first}`)).length };
  }).filter((f) => f.pax > 0).sort((a, b) => a.time.localeCompare(b.time));
  for (const f of outbound) {
    const keys = new Set<string>();
    const leg = L.find((l) => l.from === 'FXE' && l.flight === f.flight && l.tail === f.tail && l.dep === f.time && `FXE-${l.to}` === f.route);
    for (const r of outPax) if (r.flight === f.flight && (!leg || legFor(L, r, 'out') === leg)) keys.add(await paxKey(r.last, r.first, o.keySecret));
    f.ids = [...keys].sort();
  }
  const match = matchManifest(pagesOf(inbound, inPax, o.date, L), o.pool, o.feedback);
  if (suite.passengersByLast) {
    let n = 0;
    for (const m of match.matches) {
      if (m.kind !== 'surname_only' || n >= 8) continue;
      n++;
      const car = o.pool.find((c) => c.id === m.passenger_id);
      try { (m as typeof m & { check?: SurnameCheck }).check = await surnameCheck(suite, car, m.system_name, m.manifest_name, o.date); }
      catch (e) {
        const code = (e as { code?: string })?.code;
        if (code === 'BLOCKED' || code === 'LAYOUT' || code === 'LOGIN_FAILED') throw e;
        warnings.push(`last name check failed: ${m.ticket}`);
      }
    }
  }
  const settled = new Set(match.matches.filter((m) => m.kind !== 'surname_only').map((m) => m.passenger_id));

  // 2. Every Makers car we hold: Makers return date vs ours.
  const date_diffs: DateDiff[] = [], no_return: NoReturn[] = [], not_found_list: NotFound[] = [];
  let checked = 0, not_found = 0, fallbacks = 0; const suffixBudget = { n: 15 };
  const held = o.pool.filter((c) => (c.status === 'PENDING' || c.status === 'NO DATE') && String(c.return_operator || 'MAKERS').toUpperCase() !== 'ASCEND' && !settled.has(c.id));
  for (const car of held.slice(0, o.maxLookups ?? 100)) {
    const toks = normTokens(car.name);
    if (toks.length < 2) continue;
    let trips: Trip[] = [];
    try { trips = await suite.trips(toks[toks.length - 1]); } catch (e) {
      const code = (e as { code?: string })?.code;
      // A changed page or a blocked request stops the whole run (never keep going on a page we do not know).
      if (code === 'BLOCKED' || code === 'LAYOUT' || code === 'LOGIN_FAILED') throw e;
      if (code === 'DEADLINE') { warnings.push('stopped early: time limit'); break; }
      warnings.push(`lookup failed: ${car.ticket}: ${String((e as Error)?.message || e).slice(0, 120)}`); continue;
    }
    checked++;
    let t = pickTrip(car, trips, o.today);
    if (!t && suite.passengersByLast && fallbacks < 25) {
      fallbacks++;
      const ci = car.checkin || null;
      try {
        const rows = await byLastAnySuffix(suite, toks[toks.length - 1], isoToMdy(addDays(ci && ci < o.today ? ci : addDays(o.today, -120), -5)), isoToMdy(addDays(o.today, 120)), suffixBudget);
        t = tripFromFlights(car, rows, o.today);
      } catch (e) {
        const code = (e as { code?: string })?.code;
        if (code === 'BLOCKED' || code === 'LAYOUT' || code === 'LOGIN_FAILED') throw e;
        if (code === 'DEADLINE') { warnings.push('stopped early: time limit'); break; }
        warnings.push(`second lookup failed: ${car.ticket}`);
      }
    }
    if (!t) { not_found++; not_found_list.push({ passenger_id: car.id, ticket: car.ticket, system_name: car.name, ours: car.ret || null }); continue; }
    // Owner 2026-11-12 (SANTIAGO ALVAREZ 1112-1: flew out today, the robot said "Makers return 11/12", staff
    // moved our 11/15 to today, and he was on no flight back): Makers can show a Return date equal to the
    // departure day on a booking with no return yet. A same-day return counts only when the person is
    // really on a flight landing at FXE that day; otherwise it is "no return booked".
    if (t.ret && t.ret === t.dep) {
      let back = false;
      try { back = (await arrivals(t.ret)).some((r) => samePerson(car.name, r)); } catch (e) {
        const code = (e as { code?: string })?.code;
        if (code === 'BLOCKED' || code === 'LAYOUT' || code === 'LOGIN_FAILED') throw e;
        if (code === 'DEADLINE') { warnings.push('stopped early: time limit'); break; }
      }
      // The trip is often split in two bookings (first leg one-way, Return = same day; the other with the real
      // return): then the booking with a later return wins.
      if (!back) t = pickTrip(car, trips.filter((x) => x.ret && x.ret > x.dep), o.today) || { ...t, ret: '' };
    }
    const ours = parseDate(car.ret);
    if (!t.ret) { no_return.push({ passenger_id: car.id, ticket: car.ticket, system_name: car.name, ours: car.ret || null }); continue; }
    if (t.ret === ours) continue;
    date_diffs.push({ passenger_id: car.id, ticket: car.ticket, system_name: car.name, ours: car.ret || null, makers: t.ret });
  }
  if (held.length > (o.maxLookups ?? 100)) warnings.push(`only the first ${o.maxLookups ?? 100} cars were checked`);
  date_diffs.sort((a, b) => a.makers.localeCompare(b.makers));
  // 3. Follow-up guests (NO DATE) on that day's flights: arriving (manifest match) or leaving FXE (departure list).
  const followup_seen: FollowUpSeen[] = [];
  const noDate = o.pool.filter((c) => c.status === 'NO DATE');
  for (const m of match.matches) {
    const c = noDate.find((x) => x.id === m.passenger_id);
    if (c && m.kind !== 'surname_only') followup_seen.push({ passenger_id: c.id, ticket: c.ticket, system_name: c.name, direction: 'in', flight: m.flight_number, route: m.route, time: m.arrival_time });
  }
  for (const c of noDate) {
    const hit = outPax.find((r) => { const s = scoreName(c.name, { last: r.last, first: r.first, middle: '', pnr: '', first_origin: '' }); return !!s && s.kind !== 'surname_only'; });
    if (!hit) continue;
    const leg = L.find((l) => l.flight === hit.flight && l.from === 'FXE');
    followup_seen.push({ passenger_id: c.id, ticket: c.ticket, system_name: c.name, direction: 'out', flight: hit.flight, route: leg ? `FXE-${leg.to}` : `FXE-${hit.to || ''}`, time: leg ? leg.dep : '' });
  }
  const names: SyncResult['names'] = [], seenName = new Set<string>();
  for (const r of outPax) {
    const name = `${r.first} ${r.last}`.toUpperCase().replace(/[^A-Z' -]/g, ' ').replace(/\s+/g, ' ').trim();
    const leg = L.find((l) => l.flight === r.flight && l.from === 'FXE');
    if (name.length < 3 || !name.includes(' ') || !leg || seenName.has(name + '|' + r.flight)) continue;
    seenName.add(name + '|' + r.flight);
    names.push({ name, flight: r.flight, time: leg.dep, dest: leg.to });
  }
  return { date: o.date, inbound, outbound, match, date_diffs, no_return, not_found_list, checked, not_found, warnings, followup_seen, names };
}

// Owner 2026-11-19 (step 7, written OK): at check-in, the return of the ONE guest being checked in, so the
// app can show it and staff only confirm it with the guest. One read-only Makers search: the Passenger Flight
// List by last name (no 50-row cap), from 5 days ago to 120 days ahead. Return-date traps
// (feedback_makers_return_date_traps): only a real flight of that person LANDING AT FXE proves a return —
// the booking's Return Date alone never does (split bookings show Return = departure day). Pets never count.
// Nothing is stored: the answer goes back to the app only.
export type ReturnLookup =
  | { state: 'found'; ret: string; flight: string; route: string; out_date: string }
  | { state: 'no_return'; booked: string | null; out_date: string; same_day?: boolean }
  | { state: 'not_found' };
export async function lookupReturn(suite: SuiteLike, name: string, today: string): Promise<ReturnLookup> {
  const toks = normTokens(name);
  if (toks.length < 2 || !suite.passengersByLast) return { state: 'not_found' };
  const rows = (await byLastAnySuffix(suite, toks[toks.length - 1], isoToMdy(addDays(today, -5)), isoToMdy(addDays(today, 120))))
    .filter((r) => !isPetRow(r) && mdyToIso(r.date) && samePerson(name, r))
    .sort((a, b) => mdyToIso(a.date).localeCompare(mdyToIso(b.date)));
  // The flight out of FXE: today first, else the nearest day before (a guest who left yesterday and parks today).
  const outs = rows.filter((r) => r.from === 'FXE' && mdyToIso(r.date) <= addDays(today, 1) && mdyToIso(r.date) >= addDays(today, -5));
  const out = outs.find((r) => mdyToIso(r.date) === today) || outs.filter((r) => mdyToIso(r.date) < today).pop() || outs.find((r) => mdyToIso(r.date) > today);
  if (!out) return { state: 'not_found' };
  const dep = mdyToIso(out.date);
  // First flight of that person landing at FXE on a LATER day. The flight list has no times, so a flight back
  // the same day cannot be proven to land after the flight out (it may be the morning arrival): then it is
  // only a hint ("maybe a day trip — ask"), never a filled return (TV session review 2026-11-19).
  const back = rows.find((r) => r.to === 'FXE' && r !== out && mdyToIso(r.date) > dep);
  if (back) return { state: 'found', ret: mdyToIso(back.date), flight: back.flight, route: `${back.from}-FXE`, out_date: dep };
  if (rows.some((r) => r.to === 'FXE' && r !== out && mdyToIso(r.date) === dep && r.flight !== out.flight)) return { state: 'no_return', booked: dep, out_date: dep, same_day: true };
  const booked = rows.filter((r) => r.from === 'FXE' && mdyToIso(r.date) === dep).map((r) => mdyToIso(r.retDate)).filter((d) => d && d !== dep).sort().pop() || null;
  return { state: 'no_return', booked, out_date: dep };
}

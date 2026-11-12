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
export type FlightSummary = { flight: string; route: string; tail: string; time: string; pax: number; ascend: boolean; day_trips?: number; dep?: string; ids?: string[] };
// Ascend (Makers' charter brand) flights are numbered 99xx in Makers Air Suite (9948/9949 on 2026-11-06/07).
// Owner to confirm the rule; the Suite reports carry no client name to tell otherwise.
export const isAscendFlight = (flight: string) => /^99\d{2}$/.test(String(flight || '').trim());
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

export async function runSync(suite: SuiteLike, o: { date: string; today: string; pool: HeldCar[]; feedback: Feedback[]; maxLookups?: number; keySecret?: string }): Promise<SyncResult> {
  const warnings: string[] = [];
  const legsByDay = new Map<string, Leg[]>(), inByDay = new Map<string, PaxRow[]>();
  const legs = async (iso: string) => { if (!legsByDay.has(iso)) legsByDay.set(iso, await suite.schedule(isoToMdy(iso))); return legsByDay.get(iso)!; };
  const humans = (rows: PaxRow[]) => rows.filter((r) => !isPetRow(r));
  const arrivals = async (iso: string) => { if (!inByDay.has(iso)) inByDay.set(iso, humans(await suite.passengers(isoToMdy(iso), { to: 'FXE' }))); return inByDay.get(iso)!; };

  // 1. Tomorrow: arrivals and departures.
  const L = await legs(o.date), inPax = await arrivals(o.date), outPax = humans(await suite.passengers(isoToMdy(o.date), { from: 'FXE' }));
  // The report can list the same person twice (both legs of one booking): count each name once.
  const count = (rows: PaxRow[], f: string) => new Set(rows.filter((r) => r.flight === f).map((r) => `${r.last}|${r.first}`)).size;
  const inbound: FlightSummary[] = L.filter((l) => l.to === 'FXE').map((l) => ({ flight: l.flight, route: `${l.from}-FXE`, tail: l.tail, time: l.arr, dep: l.dep, pax: count(inPax, l.flight), ascend: isAscendFlight(l.flight) }))
    .filter((f) => f.pax > 0).sort((a, b) => a.time.localeCompare(b.time));
  // Departures: one line per flight (owner: destination only, no stops). Each passenger is counted once;
  // a return booked the same day is a day trip.
  const sameDay = (d: string) => { const m = d.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/); return !!m && `${m[3]}-${m[1].padStart(2, '0')}-${m[2].padStart(2, '0')}` === o.date; };
  const backToday = new Set(inPax.map((r) => `${r.last}|${r.first}`));
  const outbound: FlightSummary[] = L.filter((l) => l.from === 'FXE').map((l) => {
    const people = new Map<string, PaxRow>();
    for (const r of outPax) if (r.flight === l.flight) people.set(`${r.last}|${r.first}`, r);
    return { flight: l.flight, route: `FXE-${l.to}`, tail: l.tail, time: l.dep, pax: people.size, ascend: isAscendFlight(l.flight),
      // Owner 2026-11-07: a day trip only when Makers shows the return the SAME day AND the person is booked on a
      // flight back to FXE that day (the passenger list to FXE) — the return date alone is not enough.
      day_trips: [...people.values()].filter((r) => sameDay(r.retDate) && backToday.has(`${r.last}|${r.first}`)).length };
  }).filter((f) => f.pax > 0).sort((a, b) => a.time.localeCompare(b.time));
  for (const f of outbound) {
    const keys = new Set<string>();
    for (const r of outPax) if (r.flight === f.flight) keys.add(await paxKey(r.last, r.first, o.keySecret));
    f.ids = [...keys].sort();
  }
  const pages: ManifestPage[] = inbound.map((f) => ({
    flight_number: f.flight, manifest_date: isoToMdy(o.date).split('/').map((x, i) => i < 2 ? x.padStart(2, '0') : x).join('/'),
    route: f.route, tail_number: f.tail, arrival_time: f.time, total_pax: f.pax, ascend_mark: f.ascend,
    passengers: inPax.filter((r, i, all) => r.flight === f.flight && all.findIndex((x) => x.flight === r.flight && x.last === r.last && x.first === r.first) === i)
      .map((r) => ({ last: r.last, first: r.first, middle: '', pnr: '', first_origin: r.from })),
  }));
  const match = matchManifest(pages, o.pool, o.feedback);
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
  let checked = 0, not_found = 0;
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
    const t = pickTrip(car, trips, o.today);
    if (!t) { not_found++; not_found_list.push({ passenger_id: car.id, ticket: car.ticket, system_name: car.name, ours: car.ret || null }); continue; }
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

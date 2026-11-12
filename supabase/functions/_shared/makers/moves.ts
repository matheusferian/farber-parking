// Owner 2026-11-12 (DAVID HOCHER: on the 11:00 flight at 6 AM, moved to a 5 PM flight later that morning —
// nobody told us; also no-shows and cars made ready for nobody): every reading of a day is compared with the
// previous one of the same day, and a guest WITH A CAR here who changed flight is reported:
//   • moved — still coming that day, other flight or other time (later / earlier);
//   • off   — was on a flight, now on none (and the car is still here);
//   • on    — now on a flight that day, was on none in the previous reading.
// Surname-only pairs and delivered cars never count. Pure functions: tested without Makers.

import { flightValueFor, normRegistration, TAIL_SUFFIX_TO_REGISTRATION, type Match } from '../manifest/match.ts';

// What a reading keeps per guest (no manifest names): enough to compare the next reading. Surname-only pairs are
// kept (marked) so a pair confirmed later is not reported as "now on a flight".
export type Seen = { passenger_id: number; ticket: string; system_name: string; flight_number: string; arrival_time: string; registration: string; kind: string; state: string };
export type Move = {
  passenger_id: number; ticket: string; system_name: string; what: 'moved' | 'off' | 'on';
  was_flight?: string; was_time?: string; was_registration?: string;
  flight?: string; time?: string; registration?: string; state?: string;
};

const counts = (m: { kind: string; state?: string }) => m.kind !== 'surname_only' && m.state !== 'delivered';
export const seenOf = (ms: Match[]): Seen[] => ms.filter((m) => m.state !== 'delivered').map((m) => ({
  passenger_id: m.passenger_id, ticket: m.ticket, system_name: m.system_name, flight_number: String(m.flight_number || ''),
  arrival_time: normT(m.arrival_time), registration: m.registration || '', kind: m.kind, state: m.state,
}));
export const normT = (t: unknown) => { const m = /^(\d{1,2}):(\d{2})/.exec(String(t || '').trim()); return m ? `${m[1].padStart(2, '0')}:${m[2]}` : ''; };

// prev: the previous reading's matches (any shape with these fields; surname-only and delivered are skipped).
// held: cars still here now (PENDING / NO DATE). skipOff: guests another alert already covers (no-show).
export function diffMoves(prev: Partial<Seen>[], cur: Match[], held: Set<number>, skipOff: Set<number> = new Set()): Move[] {
  const P = new Map<number, Partial<Seen>>(), prevSurname = new Set<number>();
  for (const x of prev || []) {
    if (typeof x.passenger_id !== 'number') continue;
    if (x.kind === 'surname_only') { prevSurname.add(x.passenger_id); continue; }
    if (x.state !== 'delivered') P.set(x.passenger_id, x);
  }
  const C = new Map(cur.filter(counts).map((m) => [m.passenger_id, m]));
  const out: Move[] = [];
  for (const [id, m] of C) {
    const p = P.get(id);
    const now = { flight: String(m.flight_number || ''), time: normT(m.arrival_time), registration: m.registration || '', state: m.state };
    if (!p) {
      if (!prevSurname.has(id)) out.push({ passenger_id: id, ticket: m.ticket, system_name: m.system_name, what: 'on', ...now });
      continue;
    }
    if (String(p.flight_number || '') !== now.flight || normT(p.arrival_time) !== now.time) {
      out.push({ passenger_id: id, ticket: m.ticket, system_name: m.system_name, what: 'moved',
        was_flight: String(p.flight_number || ''), was_time: normT(p.arrival_time), was_registration: p.registration || '', ...now });
    }
  }
  for (const [id, p] of P) {
    if (C.has(id) || !held.has(id) || skipOff.has(id)) continue;
    out.push({ passenger_id: id, ticket: p.ticket || '', system_name: p.system_name || '', what: 'off',
      was_flight: String(p.flight_number || ''), was_time: normT(p.arrival_time), was_registration: p.registration || '' });
  }
  const at = (x: Move) => x.time || x.was_time || '';
  return out.sort((a, b) => at(a).localeCompare(at(b)) || a.system_name.localeCompare(b.system_name));
}

export const t12 = (t?: string) => {
  const m = /^(\d{2}):(\d{2})$/.exec(t || ''); if (!m) return t || '';
  const h = +m[1]; return `${h % 12 || 12}:${m[2]} ${h < 12 ? 'AM' : 'PM'}`;
};
// One line per guest for the push (staff app language: English).
export function moveLine(x: Move): string {
  const who = `${x.system_name} (#${x.ticket})`;
  if (x.what === 'off') return `${who}: no longer on flight ${x.was_flight}${x.was_time ? ' ' + t12(x.was_time) : ''}. Check with Makers before waiting.`;
  if (x.what === 'on') return `${who}: now on flight ${x.flight} landing ${t12(x.time)}${x.state === 'early' ? ' — earlier than our return date' : ''}.`;
  const later = (x.time || '') > (x.was_time || '');
  return `${who}: was ${t12(x.was_time)} (flight ${x.was_flight}), now ${t12(x.time)} (flight ${x.flight}).` +
    (x.time === x.was_time ? '' : later ? " Don't get the car ready yet." : ' Get the car ready sooner.');
}

// The car's own arrival time (and tail) follow a move ONLY when they still show the old flight — a value
// staff typed by hand is never overwritten, and an empty one stays for staff (tail/time are filled the day before).
export function carUpdate(x: Move, car: { departure_time?: string | null; return_flight?: string | null }): { departure_time?: string; return_flight?: string } | null {
  if (x.what !== 'moved' || x.state !== 'ok' || !x.time) return null;
  const upd: { departure_time?: string; return_flight?: string } = {};
  if (normT(car.departure_time) && normT(car.departure_time) === x.was_time && x.time !== x.was_time) upd.departure_time = x.time;
  const curF = String(car.return_flight || '').trim().toUpperCase().split(/\s+/)[0] || '';
  const curReg = TAIL_SUFFIX_TO_REGISTRATION[curF] || normRegistration(curF);
  const newVal = x.registration ? flightValueFor(x.registration) : '';
  if (upd.departure_time && curF && x.was_registration && curReg === x.was_registration && x.registration !== x.was_registration && newVal) upd.return_flight = newVal;
  return Object.keys(upd).length ? upd : null;
}

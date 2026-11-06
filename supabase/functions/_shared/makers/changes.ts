// Makers departures: what changed since the previous robot reading of the same day (owner 2026-11-06:
// "6:45 had 9 passengers, now 6 — I want to know when someone cancels, update and resend the picture
// saying what changed").
//
// Passengers are compared by an anonymous key (first 12 hex of SHA-256 of "LAST|FIRST"): no name of
// another traveller is ever stored. A key that leaves one flight and shows up on another flight the same
// day is a move ("1 moved to 10:00 AM Congo Town"); a key that disappears from the day is "cancelled or
// rebooked" (rebooked to another day looks the same from one day's list). Readings without keys (before
// 2026-11-06) fall back to the passenger counts.

export type DepFlight = { flight: string; route: string; tail: string; time: string; pax: number; ids?: string[] };
export type DepRef = { flight: string; time: string; dest: string };
export type DepChange = {
  flight: string; time: string; dest: string; tail: string;
  status?: 'new' | 'gone';                      // flight added to / removed from the day
  pax_from: number; pax_to: number;
  cancelled: number;                            // left the day (cancelled or rebooked to another day)
  added: number;                                // new on the day
  moved_out: { n: number; to: DepRef }[];
  moved_in: { n: number; from: DepRef }[];
  tail_from?: string; time_from?: string;
};

export async function paxKey(last: string, first: string): Promise<string> {
  const norm = `${String(last || '').trim().toUpperCase()}|${String(first || '').trim().toUpperCase()}`.replace(/\s+/g, ' ');
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(norm));
  return [...new Uint8Array(buf)].slice(0, 6).map((b) => b.toString(16).padStart(2, '0')).join('');
}

const dest = (f: DepFlight) => String(f.route || '').replace(/^FXE-/, '');
const ref = (f: DepFlight): DepRef => ({ flight: f.flight, time: f.time, dest: dest(f) });
// Same flight across readings: flight number + destination (Makers reuses numbers on different routes).
const fkey = (f: DepFlight) => `${f.flight}|${dest(f)}`;

export function diffDepartures(prev: DepFlight[], next: DepFlight[]): DepChange[] {
  const P = new Map(prev.map((f) => [fkey(f), f])), N = new Map(next.map((f) => [fkey(f), f]));
  const useIds = prev.every((f) => Array.isArray(f.ids)) && next.every((f) => Array.isArray(f.ids));
  const where = (list: DepFlight[]) => { const m = new Map<string, DepFlight>(); for (const f of list) for (const id of f.ids || []) m.set(id, f); return m; };
  const prevAt = useIds ? where(prev) : new Map<string, DepFlight>(), nextAt = useIds ? where(next) : new Map<string, DepFlight>();
  const out: DepChange[] = [];
  const keys = [...new Set([...P.keys(), ...N.keys()])];
  for (const k of keys) {
    const a = P.get(k), b = N.get(k), base = (b || a)!;
    const c: DepChange = { flight: base.flight, time: base.time, dest: dest(base), tail: base.tail, pax_from: a ? a.pax : 0, pax_to: b ? b.pax : 0,
      cancelled: 0, added: 0, moved_out: [], moved_in: [] };
    if (!a) c.status = 'new';
    if (!b) c.status = 'gone';
    if (a && b && a.tail !== b.tail) c.tail_from = a.tail;
    if (a && b && a.time !== b.time) c.time_from = a.time;
    if (useIds) {
      const was = new Set(a?.ids || []), now = new Set(b?.ids || []);
      const outTo = new Map<string, { n: number; to: DepRef }>(), inFrom = new Map<string, { n: number; from: DepRef }>();
      for (const id of was) if (!now.has(id)) {
        const other = nextAt.get(id);
        if (other && fkey(other) !== k) { const r = outTo.get(fkey(other)) || { n: 0, to: ref(other) }; r.n++; outTo.set(fkey(other), r); }
        else c.cancelled++;
      }
      for (const id of now) if (!was.has(id)) {
        const other = prevAt.get(id);
        if (other && fkey(other) !== k) { const r = inFrom.get(fkey(other)) || { n: 0, from: ref(other) }; r.n++; inFrom.set(fkey(other), r); }
        else c.added++;
      }
      c.moved_out = [...outTo.values()]; c.moved_in = [...inFrom.values()];
    } else if (c.pax_to < c.pax_from) c.cancelled = c.pax_from - c.pax_to;
    else if (c.pax_to > c.pax_from) c.added = c.pax_to - c.pax_from;
    if (c.status || c.tail_from || c.time_from || c.cancelled || c.added || c.moved_out.length || c.moved_in.length) out.push(c);
  }
  return out.sort((x, y) => x.time.localeCompare(y.time) || x.flight.localeCompare(y.flight));
}

const PLACE: Record<string, string> = { ASD: 'Fresh Creek', COX: 'Congo Town', GHC: 'Great Harbor Cay', GHB: "Governor's Harbour", ATC: "Arthur's Town",
  SAQ: 'San Andros', TYM: 'Staniel Cay', ELH: 'North Eleuthera', TBI: 'Cat Island', RSD: 'Rock Sound', CCZ: 'Chub Cay', SML: 'Long Island',
  MHH: 'Marsh Harbour', NAS: 'Nassau', GGT: 'Exuma', TCB: 'Treasure Cay', LGI: "Deadman's Cay", BIM: 'Bimini', ZSA: 'San Salvador' };
export const t12 = (hhmm: string) => { const m = /^(\d{1,2}):(\d{2})/.exec(hhmm || ''); if (!m) return hhmm || ''; const h = +m[1]; return `${((h + 11) % 12) + 1}:${m[2]} ${h < 12 ? 'AM' : 'PM'}`; };
const place = (code: string) => PLACE[code] || code;
const sfx = (tail: string) => String(tail || '').toUpperCase().replace(/^N\d*/, '') || String(tail || '').slice(-2);
const people = (n: number) => `${n} passenger${n === 1 ? '' : 's'}`;

// One line per flight, e.g. "6:45 AM Fresh Creek (CH): 3 cancelled or rebooked · 9 → 6".
export function changeLine(c: DepChange): string {
  const head = `${t12(c.time)} ${place(c.dest)} (${sfx(c.tail)})`;
  if (c.status === 'gone') return `${head}: flight no longer listed (${people(c.pax_from)})`;
  const bits: string[] = [];
  if (c.status === 'new') bits.push(`new flight · ${people(c.pax_to)}`);
  if (c.time_from) bits.push(`time ${t12(c.time_from)} → ${t12(c.time)}`);
  if (c.tail_from) bits.push(`aircraft ${sfx(c.tail_from)} → ${sfx(c.tail)}`);
  if (c.cancelled) bits.push(`${c.cancelled} cancelled or rebooked`);
  for (const m of c.moved_out) bits.push(`${m.n} moved to ${t12(m.to.time)} ${place(m.to.dest)}`);
  for (const m of c.moved_in) bits.push(`${m.n} moved from ${t12(m.from.time)} ${place(m.from.dest)}`);
  if (c.added && c.status !== 'new') bits.push(`${c.added} added`);
  if (c.pax_from !== c.pax_to && c.status !== 'new') bits.push(`${c.pax_from} → ${c.pax_to}`);
  return `${head}: ${bits.join(' · ')}`;
}

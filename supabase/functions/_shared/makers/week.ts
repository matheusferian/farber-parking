// Owner 2026-11-08: staff schedule. Every Monday, the next week (Mon–Sun): days with 2+ Makers departures from FXE
// at 6:45 AM, and days with 2+ at 12:45 PM. Counts only (flight, destination, people) — no names; pets excluded.
import type { Leg, PaxRow } from './suite.ts';
import { isPetRow } from './sync.ts';

export type WeekSuite = { schedule(mdy: string): Promise<Leg[]>; passengers(mdy: string, d: { from?: string; to?: string }): Promise<PaxRow[]> };
export type PeakFlight = { flight: string; dest: string; tail: string; pax: number };
export type PeakDay = { date: string; am: PeakFlight[]; noon: PeakFlight[] };
export const PEAK_TIMES = { am: '06:45', noon: '12:45' };

const isoToMdy = (iso: string) => { const [y, m, d] = iso.split('-'); return `${+m}/${+d}/${y}`; };
export function nextWeek(todayIso: string): string[] {
  const t = new Date(todayIso + 'T12:00:00Z'), dow = t.getUTCDay();          // 0 Sun … 1 Mon
  const toMon = ((8 - dow) % 7) || 7;                                        // next Monday, never today
  return Array.from({ length: 7 }, (_, i) => new Date(t.getTime() + (toMon + i) * 864e5).toISOString().slice(0, 10));
}
export async function weekPeaks(suite: WeekSuite, dates: string[]): Promise<PeakDay[]> {
  const out: PeakDay[] = [];
  for (const iso of dates) {
    const mdy = isoToMdy(iso);
    const legs = (await suite.schedule(mdy)).filter((l) => l.from === 'FXE' && (l.dep === PEAK_TIMES.am || l.dep === PEAK_TIMES.noon));
    if (legs.length < 2) { out.push({ date: iso, am: [], noon: [] }); continue; }
    const people = (await suite.passengers(mdy, { from: 'FXE' })).filter((r) => !isPetRow(r));
    const pax = (f: string) => new Set(people.filter((r) => r.flight === f).map((r) => `${r.last}|${r.first}`)).size;
    const fl = (l: Leg): PeakFlight => ({ flight: l.flight, dest: l.to, tail: l.tail, pax: pax(l.flight) });
    const am = legs.filter((l) => l.dep === PEAK_TIMES.am).map(fl).filter((f) => f.pax > 0);
    const noon = legs.filter((l) => l.dep === PEAK_TIMES.noon).map(fl).filter((f) => f.pax > 0);
    out.push({ date: iso, am: am.length >= 2 ? am : [], noon: noon.length >= 2 ? noon : [] });
  }
  return out;
}
const tailSuffix = (t: string) => String(t || '').toUpperCase().replace(/^N\d*/, '') || t;
export function weekText(days: PeakDay[]): string {
  const lines: string[] = [];
  for (const d of days) {
    if (!d.am.length && !d.noon.length) continue;
    const lab = new Date(d.date + 'T12:00:00Z').toLocaleDateString('en-US', { weekday: 'short', month: 'numeric', day: 'numeric', timeZone: 'UTC' });
    const part = (t: string, f: PeakFlight[]) => f.length ? `${t} ×${f.length} (${f.map((x) => `${tailSuffix(x.tail)} ${x.dest} ${x.pax}`).join(', ')})` : '';
    lines.push(`${lab.replace(',', '')}: ` + [part('6:45', d.am), part('12:45', d.noon)].filter(Boolean).join(' · '));
  }
  return lines.length ? lines.join('\n') : 'No day with 2+ flights at 6:45 AM or 12:45 PM.';
}

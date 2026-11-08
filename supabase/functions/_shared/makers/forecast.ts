// Owner 2026-11-08: demand forecast for the parking lot and the staff schedule. People booked per day leaving FXE
// (cars coming in) and arriving at FXE (cars going home), counts only — names are read only to count each person
// once and are never kept; pets excluded.
import type { PaxRow } from './suite.ts';
import { isPetRow } from './sync.ts';

export type ForecastSuite = { passengersRange(fromMdy: string, toMdy: string): Promise<PaxRow[]> };
export type ForecastDay = { day: string; departures: number; arrivals: number };

const mdy = (iso: string) => { const [y, m, d] = iso.split('-'); return `${+m}/${+d}/${y}`; };
const isoOf = (m: string) => { const p = m.split('/'); return `${p[2]}-${p[0].padStart(2, '0')}-${p[1].padStart(2, '0')}`; };
const addDays = (iso: string, n: number) => new Date(Date.parse(iso + 'T12:00:00Z') + n * 864e5).toISOString().slice(0, 10);

export async function forecastDays(suite: ForecastSuite, todayIso: string, days = 200, chunk = 28): Promise<ForecastDay[]> {
  const out = new Map<string, Set<string>>(), inn = new Map<string, Set<string>>();
  for (let start = 0; start < days; start += chunk) {
    const a = addDays(todayIso, start), b = addDays(todayIso, Math.min(days, start + chunk) - 1);
    for (const r of await suite.passengersRange(mdy(a), mdy(b))) {
      if (isPetRow(r)) continue;
      const day = isoOf(r.date), who = `${r.last}|${r.first}`;
      if (r.from === 'FXE') { if (!out.has(day)) out.set(day, new Set()); out.get(day)!.add(who); }
      if (r.to === 'FXE') { if (!inn.has(day)) inn.set(day, new Set()); inn.get(day)!.add(who); }
    }
  }
  return Array.from({ length: days }, (_, i) => addDays(todayIso, i))
    .map((day) => ({ day, departures: out.get(day)?.size ?? 0, arrivals: inn.get(day)?.size ?? 0 }));
}

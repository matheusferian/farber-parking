// Thermal slips for the Makers manifest (owner 2026-11-27): one slip per flight, printed by the Epson
// TM-m30II itself through Server Direct Print (the printer asks printer-poll every few seconds).
//   8 AM  → today's cars going out (flights landing 11 AM or later, plus any not printed the day before)
//   2 PM  → tomorrow's cars on flights landing before 11 AM
// Only name, flight and arrival time are printed.

export type Pax = { id: number; name: string; return_flight?: string | null; departure_time?: string | null };
export type Match = { passenger_id: number; registration?: string | null; flight_number?: string | null; arrival_time?: string | null; kind?: string };
export type Slip = { flight: string; time: string; names: string[]; ids: number[] };

const hhmm = (t?: string | null) => { const m = String(t || '').match(/^(\d{1,2}):(\d{2})/); return m ? `${m[1].padStart(2, '0')}:${m[2]}` : ''; };
export const ampm = (t: string) => {
  const m = t.match(/^(\d{2}):(\d{2})$/); if (!m) return '';
  const h = +m[1]; return `${h % 12 || 12}:${m[2]} ${h < 12 ? 'AM' : 'PM'}`;
};

// Groups the cars by flight, ordered by arrival time. `keep(time)` picks which arrivals go on this print.
export function buildSlips(pax: Pax[], matches: Match[], keep: (time: string) => boolean): Slip[] {
  const byId = new Map<number, Match>();
  for (const m of matches) if (m && m.passenger_id && m.kind !== 'surname_only') byId.set(m.passenger_id, m);
  const groups = new Map<string, Slip>();
  for (const p of pax) {
    const m = byId.get(p.id);
    const time = hhmm(m?.arrival_time) || hhmm(p.departure_time);
    if (!keep(time)) continue;
    const tail = String(m?.registration || p.return_flight || '').trim().toUpperCase() || 'NO FLIGHT';
    const num = String(m?.flight_number || '').trim();
    const flight = num ? `${tail} #${num}` : tail;
    const key = `${time}|${flight}`;
    const g = groups.get(key) || { flight, time, names: [], ids: [] };
    g.names.push(String(p.name || '').trim().toUpperCase().slice(0, 40)); g.ids.push(p.id);
    groups.set(key, g);
  }
  const out = [...groups.values()];
  for (const g of out) g.names.sort();
  return out.sort((a, b) => (a.time || '99:99').localeCompare(b.time || '99:99') || a.flight.localeCompare(b.flight));
}

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

// ePOS-Print XML: one cut per flight. `day` like "Fri 11/27", `stamp` like "Printed 11/27 8:00 AM - Air Valet".
export function eposXml(slips: Slip[], day: string, stamp: string): string {
  const one = (s: Slip) => {
    const cars = `${s.names.length} ${s.names.length === 1 ? 'car' : 'cars'}`;
    const arr = s.time ? `Arrival time ${ampm(s.time)}` : 'Arrival time not set';
    return '<text align="center"/><text dw="true" dh="true" em="true"/>' + `<text>${esc(s.flight)}&#10;</text>`
      + '<text dw="false" dh="false" em="true"/>' + `<text>${esc(day)}&#10;${esc(arr)}   -   ${cars}&#10;&#10;</text>`
      + '<text align="left"/><text em="false" linespc="40"/>' + s.names.map((n) => `<text>${esc(n)}&#10;</text>`).join('')
      + '<text>&#10;</text><text align="center"/><text font="font_b"/>' + `<text>${esc(stamp)}&#10;</text>`
      + '<text font="font_a"/><feed line="3"/><cut type="feed"/>';
  };
  return '<epos-print xmlns="http://www.epson-pos.com/schemas/2011/03/epos-print"><text lang="en"/><text font="font_a"/>'
    + slips.map(one).join('') + '</epos-print>';
}

// Server Direct Print answer to a GetRequest.
export function printRequestInfo(epos: string, jobId: string): string {
  return '<?xml version="1.0" encoding="utf-8"?><PrintRequestInfo Version="2.00"><ePOSPrint><Parameter>'
    + `<devid>local_printer</devid><timeout>10000</timeout><printjobid>${esc(jobId)}</printjobid>`
    + `</Parameter><PrintData>${epos}</PrintData></ePOSPrint></PrintRequestInfo>`;
}

// Plain-text look of the slips (for previews and tests).
export function preview(slips: Slip[], day: string, stamp: string): string {
  return slips.map((s) => `${s.flight}\n${day}\n${s.time ? 'Arrival time ' + ampm(s.time) : 'Arrival time not set'}   -   ${s.names.length} ${s.names.length === 1 ? 'car' : 'cars'}\n\n${s.names.join('\n')}\n\n  ${stamp}`)
    .join('\n' + '-'.repeat(40) + '\n');
}

// Which print is due now (Fort Lauderdale clock). Returns null outside the windows.
export function dueJob(etDate: string, etTomorrow: string, hour: number): { key: string; date: string; kind: 'am' | 'pm' } | null {
  if (hour >= 8 && hour < 12) return { key: `am-${etDate}`, date: etDate, kind: 'am' };
  if (hour >= 14 && hour < 20) return { key: `pm-${etTomorrow}`, date: etTomorrow, kind: 'pm' };
  return null;
}
export const keepFor = (kind: 'am' | 'pm') => (t: string) => kind === 'pm' ? (t !== '' && t < '11:00') : true;

// Makers Air Suite reader (owner 2026-11-06). READ-ONLY by rule: it logs in and runs two SEARCH
// reports, nothing else. It never opens a flight edit form, never posts a Save/Add/Delete button,
// and keeps only what AirValet needs: flight number, route, times, tail, passenger names, counts.
//   1. Reservations/FlightSchedule.aspx  ("Flight Schedule AG")   → legs with times and tail
//   2. PassangerFlightReport.aspx        ("Passenger Flight List") → passenger names per flight
// The parsers are pure functions (tested with small HTML samples); the I/O is in MakersSuite.

export const SUITE = 'https://makerssuite.com';

export type Leg = { date: string; dep: string; arr: string; flight: string; from: string; to: string; tail: string };
export type PaxRow = { date: string; flight: string; from: string; to: string; last: string; first: string; retDate: string };
// View Reservation search result, reduced to what AirValet needs (no PNR, no date of birth).
export type Trip = { last: string; first: string; dep: string; depTime: string; ret: string; retTime: string };

// "11:01 AM" → "11:01", "5:41 PM" → "17:41"
export function to24(t: string): string {
  const m = String(t || '').trim().match(/^(\d{1,2}):(\d{2})\s*([AP])M$/i);
  if (!m) return '';
  let h = +m[1] % 12;
  if (m[3].toUpperCase() === 'P') h += 12;
  return `${String(h).padStart(2, '0')}:${m[2]}`;
}

// Light HTML reading (no DOM: an Edge Function has ~2 s of CPU and these pages are 200–400 KB).
const ENT: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ', '#39': "'" };
export function decode(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+|#39);/gi, (m, e: string) => {
    if (ENT[e.toLowerCase()] !== undefined) return ENT[e.toLowerCase()];
    if (e[0] === '#') { const n = e[1].toLowerCase() === 'x' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10); return Number.isFinite(n) ? String.fromCodePoint(n) : m; }
    return m;
  });
}
const text = (h: string) => decode(h.replace(/<[^>]*>/g, ' ')).replace(/\s+/g, ' ').trim();
function rowsOf(html: string): string[][] {
  // Each row runs from its <tr> to its </tr> or to the next <tr>, whichever comes first, so the
  // rows of a table nested in a layout row are all kept (the layout row itself holds <table>: skipped).
  const out: string[][] = [], low = html.toLowerCase();
  const starts = [...low.matchAll(/<tr\b/g)].map((m) => m.index!);
  starts.forEach((st, i) => {
    const next = i + 1 < starts.length ? starts[i + 1] : low.length;
    const close = low.indexOf('</tr', st);
    const end = close >= 0 && close < next ? close : next;
    const chunk = html.slice(st, end);
    if (/<table\b/i.test(chunk)) return;
    out.push([...chunk.matchAll(/<t[dh]\b[^>]*>([\s\S]*?)(?=<\/t[dh]>|<t[dh]\b|$)/gi)].map((c) => text(c[1])));
  });
  return out;
}
const attr = (tag: string, name: string): string | null => {
  const m = tag.match(new RegExp(`\\s${name}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s>]+))`, 'i'));
  return m ? decode(m[2] ?? m[3] ?? m[4] ?? '') : null;
};
const hasAttr = (tag: string, name: string) => new RegExp(`\\s${name}(\\s|=|>|/)`, 'i').test(tag);

// Flight Schedule AG grid: # | Flight Date | Departure | Arrival | DOW | Flight | From | To | Open | Tail Num | Captain | Co-Pilot
export function parseSchedule(html: string): Leg[] {
  return rowsOf(html).filter((c) => c.length >= 10 && /^\d+$/.test(c[0]) && /^\d{2}\/\d{2}\/\d{4}$/.test(c[1]))
    .map((c) => ({ date: c[1], dep: to24(c[2]), arr: to24(c[3]), flight: c[5], from: c[6].toUpperCase(), to: c[7].toUpperCase(), tail: c[9].toUpperCase() }));
}

// Passenger Flight List grid: # | Date | Flight | PNR | From | TO | Pax Name ("LAST, FIRST") | Return Date | Return … | Agent
// Only date, flight, route, name and the return DATE are kept (no PNR, no agent): the return date tells a day trip.
export function parsePassengers(html: string): PaxRow[] {
  return rowsOf(html).filter((c) => c.length >= 7 && /^\d+$/.test(c[0]) && /^\d{1,2}\/\d{1,2}\/\d{4}$/.test(c[1]))
    .map((c) => {
      const [last, first] = c[6].split(',').map((s) => s.trim());
      return { date: c[1], flight: c[2], from: c[4].toUpperCase(), to: c[5].toUpperCase(), last: (last || '').toUpperCase(), first: (first || '').toUpperCase(),
        retDate: /^\d{1,2}\/\d{1,2}\/\d{4}$/.test(c[7] || '') ? c[7] : '' };
    }).filter((p) => p.last);
}

// View Reservation grid: PNR | Booked Date | Last Name | First Name | Date Of Birth | Departure | Return | Select
// Columns are found by header name; date of birth and PNR are never read.
export function parseTrips(html: string): Trip[] {
  const out: Trip[] = [];
  let hdr: string[] | null = null;
  for (const c of rowsOf(html)) {
    if (c.includes('Last Name') && c.includes('Return')) { hdr = c; continue; }
    if (!hdr || c.length !== hdr.length) continue;
    const g = (h: string) => c[hdr!.indexOf(h)] || '';
    const split = (v: string) => { const m = v.match(/^(\d{2})\/(\d{2})\/(\d{4})\s+(\d{2}:\d{2})/); return m ? [`${m[3]}-${m[1]}-${m[2]}`, m[4]] : ['', '']; };
    const [dep, depTime] = split(g('Departure')), [ret, retTime] = split(g('Return'));
    if (g('Last Name')) out.push({ last: g('Last Name').toUpperCase(), first: g('First Name').toUpperCase(), dep, depTime, ret, retTime });
  }
  return out;
}

// Every named form field, as the browser would post it (submit buttons excluded: the caller adds the one it presses).
export function formFields(html: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const m of html.matchAll(/<input\b[^>]*>/gi)) {
    const tag = m[0], name = attr(tag, 'name'), type = String(attr(tag, 'type') || 'text').toLowerCase();
    if (!name || ['submit', 'button', 'image', 'reset', 'file'].includes(type)) continue;
    if ((type === 'checkbox' || type === 'radio') && !hasAttr(tag, 'checked')) continue;
    out.set(name, attr(tag, 'value') ?? '');
  }
  for (const m of html.matchAll(/<select\b([^>]*)>([\s\S]*?)<\/select>/gi)) {
    const name = attr('<x' + m[1] + '>', 'name'); if (!name) continue;
    const opts = [...m[2].matchAll(/<option\b([^>]*)>([\s\S]*?)<\/option>/gi)];
    // A list with no options is not sent by a browser; sending it makes ASP.NET answer 500.
    if (!opts.length) continue;
    const sel = opts.find((o) => hasAttr('<x' + o[1] + '>', 'selected')) || opts[0];
    out.set(name, attr('<x' + sel[1] + '>', 'value') ?? text(sel[2]));
  }
  return out;
}

// Telerik RadDatePicker: the visible text, the hidden ISO value and the client-state JSON must agree.
export function setRadDate(f: Map<string, string>, picker: string, mdy: string): void {
  const [m, d, y] = mdy.split('/');
  const iso = `${y}-${m.padStart(2, '0')}-${d.padStart(2, '0')}`;
  for (const k of [...f.keys()]) {
    if (k.endsWith(`${picker}$dateInput`)) f.set(k, mdy);
    else if (k.endsWith(`$${picker}`)) f.set(k, iso);
    else if (k.endsWith(`${picker}_dateInput_ClientState`)) {
      let o: Record<string, unknown> = {};
      try { o = JSON.parse(f.get(k) || '{}'); } catch { o = {}; }
      Object.assign(o, { enabled: true, emptyMessage: '', validationText: `${iso}-00-00-00`, valueAsString: `${iso}-00-00-00`, lastSetTextBoxValue: mdy });
      f.set(k, JSON.stringify(o));
    }
  }
}

export class MakersSuiteError extends Error { constructor(public code: 'LOGIN_FAILED' | 'HTTP' | 'LAYOUT', msg: string) { super(msg); } }

export class MakersSuite {
  private cookies = new Map<string, string>();
  private pageCache = new Map<string, string>();   // a search page's blank form, reused for the next search
  constructor(private fetchImpl: typeof fetch = fetch) {}

  private async req(path: string, body?: URLSearchParams): Promise<{ status: number; html: string; location: string | null }> {
    const res = await this.fetchImpl(SUITE + path, {
      method: body ? 'POST' : 'GET', redirect: 'manual', body,
      headers: { ...(body ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}), Cookie: [...this.cookies].map(([k, v]) => `${k}=${v}`).join('; '), 'User-Agent': 'AirValet-MakersSync/1.0' },
      signal: AbortSignal.timeout(30_000),
    });
    for (const c of res.headers.getSetCookie?.() ?? []) {
      const [kv] = c.split(';'); const i = kv.indexOf('=');
      if (i > 0) this.cookies.set(kv.slice(0, i).trim(), kv.slice(i + 1).trim());
    }
    const html = await res.text();
    if (res.status >= 500) throw new MakersSuiteError('HTTP', `${path} → ${res.status}`);
    return { status: res.status, html, location: res.headers.get('location') };
  }
  private async getFollow(path: string): Promise<string> {
    let r = await this.req(path);
    for (let i = 0; i < 3 && r.status >= 300 && r.status < 400 && r.location; i++) {
      const loc = r.location.startsWith('http') ? new URL(r.location).pathname + new URL(r.location).search : '/' + r.location.replace(/^\.?\//, '');
      if (/login/i.test(loc)) throw new MakersSuiteError('LOGIN_FAILED', 'session expired');
      r = await this.req(loc);
    }
    return r.html;
  }

  async login(user: string, pass: string): Promise<void> {
    const page = await this.req('/Login.aspx');
    const f = formFields(page.html);
    const u = [...f.keys()].find((k) => k.endsWith('Login1$UserName')), p = [...f.keys()].find((k) => k.endsWith('Login1$Password'));
    if (!u || !p) throw new MakersSuiteError('LAYOUT', 'login form not found');
    f.set(u, user); f.set(p, pass);
    const btn = u.replace(/UserName$/, 'LoginButton');
    const body = new URLSearchParams([...f.entries()]); body.set(btn, 'Log In');
    const r = await this.req('/Login.aspx', body);
    const ok = (r.status >= 300 && r.status < 400 && r.location && !/login/i.test(r.location)) || (r.status === 200 && !/Login1\$UserName/.test(r.html) && /Logout/i.test(r.html));
    if (!ok) throw new MakersSuiteError('LOGIN_FAILED', 'Makers Air Suite did not accept the login');
  }

  // Runs a page's own Search button for one day. Only the search button is ever pressed.
  private async search(path: string, pickers: string[], button: string, mdy: string, extra: Record<string, string> = {},
    textStates: Record<string, string> = {}): Promise<string> {
    const html = this.pageCache.get(path) ?? await this.getFollow(path);
    this.pageCache.set(path, html);
    const f = formFields(html);
    for (const pk of pickers) setRadDate(f, pk, mdy);
    for (const [suffix, v] of Object.entries(extra)) {
      const keys = [...f.keys()].filter((k) => k.endsWith(suffix));
      if (keys.length) for (const k of keys) f.set(k, v);
      else if (suffix === '$CheckBoxAnyDate' && v) {   // an unchecked checkbox is not in the form: add it
        const any = [...f.keys()].find((k) => k.includes('FindReservation1$'));
        if (any) f.set(any.replace(/FindReservation1\$.*$/, 'FindReservation1$CheckBoxAnyDate'), v);
      }
    }
    // Telerik RadTextBox keeps its value in a JSON client state too.
    for (const [suffix, v] of Object.entries(textStates)) for (const k of [...f.keys()]) if (k.endsWith(suffix)) {
      let o: Record<string, unknown> = {}; try { o = JSON.parse(f.get(k) || '{}'); } catch { o = {}; }
      Object.assign(o, { enabled: true, emptyMessage: '', validationText: v, valueAsString: v, lastSetTextBoxValue: v }); f.set(k, JSON.stringify(o));
    }
    const bt = [...html.matchAll(/<input\b[^>]*>/gi)].map((m) => m[0])
      .find((t) => String(attr(t, 'type') || '').toLowerCase() === 'submit' && String(attr(t, 'name') || '').endsWith(button));
    if (!bt) throw new MakersSuiteError('LAYOUT', `${path}: search button not found`);
    const body = new URLSearchParams([...f.entries()]); body.set(attr(bt, 'name')!, attr(bt, 'value') || 'Search');
    const r = await this.req(path, body);
    if (r.status >= 300 && r.status < 400 && /login/i.test(r.location || '')) throw new MakersSuiteError('LOGIN_FAILED', 'session expired');
    return r.html;
  }

  async schedule(mdy: string): Promise<Leg[]> {
    const html = await this.search('/Reservations/FlightSchedule.aspx', ['RadDatePicker_DateSearchFrom', 'RadDatePicker_DateSearchTo'], 'Button_DateSearch', mdy);
    if (!/Tail\s*Num/i.test(html)) throw new MakersSuiteError('LAYOUT', 'flight schedule grid not found');
    return parseSchedule(html);
  }

  // Reservations → View Reservation, search by name, any date. Read-only search.
  async trips(last: string, first = ''): Promise<Trip[]> {
    const html = await this.search('/Reservations/ViewReservation.aspx', [], 'ButtonSearch', '1/1/2000', {
      '$RadTextBoxLastName': last, '$RadTextBoxFirstName': first, '$RadTextBoxPNR': '', '$CheckBoxAnyDate': 'on',
    }, { '_RadTextBoxLastName_ClientState': last, '_RadTextBoxFirstName_ClientState': first, '_RadTextBoxPNR_ClientState': '' });
    return parseTrips(html);
  }

  async passengers(mdy: string, dir: { to?: string; from?: string }): Promise<PaxRow[]> {
    const html = await this.search('/PassangerFlightReport.aspx', ['RadDate_StartDate', 'RadDate_EndDate'], 'btnsearch', mdy,
      { '$txtto': dir.to || '', '$txtFrom': dir.from || '' });
    if (!/Pax Name/i.test(html)) throw new MakersSuiteError('LAYOUT', 'passenger list grid not found');
    return parsePassengers(html);
  }
}

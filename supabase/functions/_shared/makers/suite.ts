// Makers Air Suite reader (owner 2026-11-06). READ-ONLY by rule — see supabase/functions/makers-sync/SECURITY.md.
// Enforced in code, not only by habit (security review 2026-11-06):
//   • only 4 paths can ever be requested (ALLOWED_PATHS); a redirect anywhere else stops the run;
//   • POST only to the login and the 3 search pages, pressing only a button whose name ends with its
//     Search button and contains "search"; __EVENTTARGET/__EVENTARGUMENT always blank; any field named
//     like an action (save/add/delete/update/edit/…) or another button is dropped before posting;
//   • responses capped at 6 MB, 30 s per request, one overall deadline per run, a short pause between requests.
// It logs in and runs SEARCH reports, nothing else. It never opens a flight edit form, never posts a Save/Add/Delete button,
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
  const m = String(t || '').trim().match(/^(\d{1,2}):([0-5]\d)\s*([AP])M$/i);
  if (!m || +m[1] < 1 || +m[1] > 12) return '';
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

export class MakersSuiteError extends Error { constructor(public code: 'LOGIN_FAILED' | 'HTTP' | 'LAYOUT' | 'BLOCKED' | 'DEADLINE', msg: string) { super(msg); } }

// The only pages the robot may ever open (case-insensitive, no query string).
export const ALLOWED_PATHS = ['/Login.aspx', '/Reservations/FlightSchedule.aspx', '/PassangerFlightReport.aspx', '/Reservations/ViewReservation.aspx'];
const SEARCH_PATHS = ALLOWED_PATHS.slice(1).map((p) => p.toLowerCase());
export function allowedPath(path: string): boolean {
  return /^\/[A-Za-z0-9_\/.-]+$/.test(path) && ALLOWED_PATHS.some((p) => p.toLowerCase() === path.toLowerCase());
}
// Field names that look like an action: never posted, whatever the page puts in its form.
const ACTION_NAME = /(save|add|delete|del|remove|update|upd|edit|insert|ins|cancel|void|approve|confirm|submit|book|pay|refund|send|post|create|new|copy|move|assign|change|reset)$/i;
// The form the robot posts for one search: page fields minus anything that could trigger an action.
export function safeSearchForm(html: string, f: Map<string, string>, button: string): Map<string, string> {
  const buttons = [...html.matchAll(/<input\b[^>]*>/gi)].map((m) => m[0])
    .filter((t) => ['submit', 'button', 'image'].includes(String(attr(t, 'type') || '').toLowerCase())).map((t) => attr(t, 'name')).filter(Boolean) as string[];
  const out = new Map<string, string>();
  for (const [k, v] of f) {
    const last = k.split(/[$:]/).pop() || k;
    if (buttons.includes(k)) continue;
    if (!k.startsWith('__') && ACTION_NAME.test(last) && !/^(RadDate|RadDatePicker|RadTextBox|txt|ddl|CheckBox|hf)/i.test(last)) continue;
    out.set(k, v);
  }
  out.set('__EVENTTARGET', ''); out.set('__EVENTARGUMENT', '');
  if (!/search/i.test(button)) throw new MakersSuiteError('BLOCKED', 'only a Search button can be pressed');
  return out;
}

// Reads at most `max` bytes of a response (a page is 200–400 KB; anything far bigger is not a report).
export async function readCapped(res: Response, max: number): Promise<string> {
  if (!res.body) return '';
  const reader = res.body.getReader(), parts: Uint8Array[] = []; let n = 0;
  for (;;) {
    const { done, value } = await reader.read(); if (done) break;
    n += value.byteLength;
    if (n > max) { try { await reader.cancel(); } catch { /* ignore */ } throw new MakersSuiteError('LAYOUT', 'response too large'); }
    parts.push(value);
  }
  const all = new Uint8Array(n); let o = 0; for (const p of parts) { all.set(p, o); o += p.byteLength; }
  return new TextDecoder().decode(all);
}

export class MakersSuite {
  private cookies = new Map<string, string>();
  private pageCache = new Map<string, string>();   // a search page's blank form, reused for the next search
  private deadline: number;
  private lastAt = 0;
  requests = 0;
  constructor(private fetchImpl: typeof fetch = fetch, o: { deadlineMs?: number; pauseMs?: number; maxRequests?: number } = {}) {
    this.deadline = Date.now() + (o.deadlineMs ?? 110_000); this.pauseMs = o.pauseMs ?? 250; this.maxRequests = o.maxRequests ?? 150;
  }
  private pauseMs: number;
  private maxRequests: number;

  private async req(path: string, body?: URLSearchParams): Promise<{ status: number; html: string; location: string | null }> {
    if (!allowedPath(path)) throw new MakersSuiteError('BLOCKED', `path not allowed: ${path.slice(0, 60)}`);
    if (body && !(path.toLowerCase() === '/login.aspx' || SEARCH_PATHS.includes(path.toLowerCase()))) throw new MakersSuiteError('BLOCKED', 'POST not allowed');
    if (Date.now() > this.deadline) throw new MakersSuiteError('DEADLINE', 'run took too long');
    if (++this.requests > this.maxRequests) throw new MakersSuiteError('DEADLINE', 'too many requests');
    const wait = this.lastAt + this.pauseMs - Date.now(); if (wait > 0) await new Promise((r) => setTimeout(r, wait));
    this.lastAt = Date.now();
    const res = await this.fetchImpl(SUITE + path, {
      method: body ? 'POST' : 'GET', redirect: 'manual', body,
      headers: { ...(body ? { 'Content-Type': 'application/x-www-form-urlencoded' } : {}), Cookie: [...this.cookies].map(([k, v]) => `${k}=${v}`).join('; '), 'User-Agent': 'AirValet-MakersSync/1.0' },
      signal: AbortSignal.timeout(30_000),
    });
    for (const c of res.headers.getSetCookie?.() ?? []) {
      const [kv] = c.split(';'); const i = kv.indexOf('=');
      if (i > 0) this.cookies.set(kv.slice(0, i).trim(), kv.slice(i + 1).trim());
    }
    const html = await readCapped(res, 6 * 1024 * 1024);
    if (res.status >= 500) throw new MakersSuiteError('HTTP', `${path} → ${res.status}`);
    return { status: res.status, html, location: res.headers.get('location') };
  }
  private async getFollow(path: string): Promise<string> {
    let r = await this.req(path);
    for (let i = 0; i < 3 && r.status >= 300 && r.status < 400 && r.location; i++) {
      let loc: string;
      try { const u = new URL(r.location, SUITE + path); if (u.origin !== SUITE) throw new Error('off-site'); loc = u.pathname; }
      catch { throw new MakersSuiteError('BLOCKED', 'redirect off Makers Air Suite'); }
      if (/login/i.test(loc)) throw new MakersSuiteError('LOGIN_FAILED', 'session expired');
      if (loc.toLowerCase() !== path.toLowerCase()) throw new MakersSuiteError('BLOCKED', 'redirected to another page');
      r = await this.req(loc);
    }
    if (r.status >= 300) throw new MakersSuiteError('LAYOUT', `${path} → ${r.status}`);
    return r.html;
  }

  async login(user: string, pass: string): Promise<void> {
    const page = await this.req('/Login.aspx');
    const f = formFields(page.html);
    const u = [...f.keys()].find((k) => k.endsWith('Login1$UserName')), p = [...f.keys()].find((k) => k.endsWith('Login1$Password'));
    if (!u || !p) throw new MakersSuiteError('LAYOUT', 'login form not found');
    f.set(u, user); f.set(p, pass); f.set('__EVENTTARGET', ''); f.set('__EVENTARGUMENT', '');
    const btn = u.replace(/UserName$/, 'LoginButton');
    const body = new URLSearchParams([...f.entries()]); body.set(btn, 'Log In');
    const r = await this.req('/Login.aspx', body);
    const ok = (r.status >= 300 && r.status < 400 && r.location && !/login/i.test(r.location)) || (r.status === 200 && !/Login1\$UserName/.test(r.html) && /Logout/i.test(r.html));
    if (!ok) throw new MakersSuiteError('LOGIN_FAILED', 'Makers Air Suite did not accept the login');
  }

  // Runs a page's own Search button for one day. Only the search button is ever pressed.
  private async search(path: string, pickers: string[], button: string, mdy: string, extra: Record<string, string> = {},
    textStates: Record<string, string> = {}, mdyTo = mdy): Promise<string> {
    const html = this.pageCache.get(path) ?? await this.getFollow(path);
    this.pageCache.set(path, html);
    const f = formFields(html);
    pickers.forEach((pk, i) => setRadDate(f, pk, i === 1 ? mdyTo : mdy));   // [from, to]: a range when mdyTo differs
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
      .find((t) => String(attr(t, 'type') || '').toLowerCase() === 'submit' && (String(attr(t, 'name') || '').split('$').pop() || '') === button);
    if (!bt) throw new MakersSuiteError('LAYOUT', `${path}: search button not found`);
    const body = new URLSearchParams([...safeSearchForm(html, f, button).entries()]); body.set(attr(bt, 'name')!, attr(bt, 'value') || 'Search');
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

  // Owner 2026-11-12 (same last name check): every flight of one last name over a date range, every route.
  // Read-only; the Passenger Flight List has no paging limit (View Reservation stops at 50 rows, oldest first).
  async passengersByLast(last: string, fromMdy: string, toMdy: string): Promise<PaxRow[]> {
    const html = await this.search('/PassangerFlightReport.aspx', ['RadDate_StartDate', 'RadDate_EndDate'], 'btnsearch', fromMdy,
      { '$txtto': '', '$txtFrom': '', '$txtlastname': last }, {}, toMdy);
    if (!/Pax Name/i.test(html)) throw new MakersSuiteError('LAYOUT', 'passenger list grid not found');
    return parsePassengers(html).filter((r) => r.last === last.toUpperCase());
  }

  // Owner 2026-11-08 (demand forecast): the same passenger list search over a date range, every route. Read-only.
  async passengersRange(fromMdy: string, toMdy: string): Promise<PaxRow[]> {
    const html = await this.search('/PassangerFlightReport.aspx', ['RadDate_StartDate', 'RadDate_EndDate'], 'btnsearch', fromMdy,
      { '$txtto': '', '$txtFrom': '' }, {}, toMdy);
    if (!/Pax Name/i.test(html)) throw new MakersSuiteError('LAYOUT', 'passenger list grid not found');
    return parsePassengers(html);
  }
}

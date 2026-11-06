// Makers manifest ↔ AirValet matcher (2026-11-06, owner). Pure: no I/O, no AI.
//
// Claude only READS the manifest pages (manifest-scan). This file decides who is who, with fixed
// rules, so the same input always gives the same answer and every match can be explained.
// The manifest is the source of truth for names: our system can have a typo ("MATEUS" for
// "MATHEUS", "MATHEUW"), the manifest does not. A close match comes back with the corrected name.
//
// Matching only considers the cars we hold (status PENDING) plus cars delivered on the manifest
// day, never the whole customer base, and each passenger is matched to at most one manifest row.

export type ManifestPassenger = { last: string; first: string; middle: string; pnr: string; first_origin: string; uncertain?: boolean };
export type ManifestPage = {
  flight_number: string; manifest_date: string; route: string; tail_number: string; arrival_time: string;
  total_pax: number; ascend_mark: boolean; client_name?: string; passengers: ManifestPassenger[];
};
export type Candidate = {
  id: number; ticket: string; name: string; ret: string | null; status: string; deldate?: string | null;
  return_flight?: string | null; departure_time?: string | null; return_operator?: string | null;
};
export type Feedback = { manifest_name: string; system_name: string; verdict: 'same' | 'different' };

export type MatchKind = 'exact' | 'typo' | 'nickname' | 'surname_only' | 'taught';
export type MatchState = 'ok' | 'early' | 'late' | 'no_date' | 'delivered';
export type Match = {
  passenger_id: number; ticket: string; system_name: string; manifest_name: string; kind: MatchKind; score: number;
  state: MatchState; ret: string | null; manifest_date: string; operator: string | null;
  flight_number: string; route: string; registration: string; arrival_time: string; day_trip: boolean; ascend: boolean;
  suggest_name: string | null;            // manifest spelling, when ours differs
  suggest_flight: string | null;          // value for return_flight (tail suffix the app uses, e.g. "RV"), when ours differs
  suggest_time: string | null;            // value for departure_time ("HH:MM"), when ours differs
  current_flight: string; current_time: string;
};
export type Missing = { passenger_id: number; ticket: string; system_name: string; ret: string | null; operator: string | null };
export type MatchResult = { manifest_date: string | null; matches: Match[]; missing: Missing[]; manifest_rows: number };

// The app's own map (index.html TAIL_SUFFIX_TO_REGISTRATION): staff type the last two letters.
export const TAIL_SUFFIX_TO_REGISTRATION: Record<string, string> = {
  JH: 'N208JH', RV: 'N740RV', DD: 'N821DD', CH: 'N310CH', WM: 'N146WM', DH: 'N512DH', AH: 'N633AH', JR: 'N624JR',
};

const SUFFIXES = new Set(['JR', 'SR', 'II', 'III', 'IV', 'V']);
const NICKNAMES: Record<string, string[]> = {
  MICHAEL: ['MIKE', 'MIKEY', 'MICK'], WILLIAM: ['BILL', 'WILL', 'BILLY', 'WILLIE', 'LIAM'], ROBERT: ['BOB', 'ROB', 'BOBBY', 'ROBBIE', 'BERT'],
  THOMAS: ['TOM', 'TOMMY'], JAMES: ['JIM', 'JIMMY', 'JAMIE'], DANIEL: ['DAN', 'DANNY'], DAVID: ['DAVE', 'DAVEY'],
  CHRISTOPHER: ['CHRIS'], CHRISTINE: ['CHRIS', 'CHRISSY'], MATTHEW: ['MATT'], JOSEPH: ['JOE', 'JOEY'], ANTHONY: ['TONY'],
  RICHARD: ['RICK', 'RICH', 'RICKY', 'DICK'], STEPHEN: ['STEVE'], STEVEN: ['STEVE'], KENNETH: ['KEN', 'KENNY'],
  RONALD: ['RON', 'RONNIE'], TIMOTHY: ['TIM', 'TIMMY'], JEFFREY: ['JEFF'], GREGORY: ['GREG'], NICHOLAS: ['NICK', 'NICKY'],
  SAMUEL: ['SAM', 'SAMMY'], SAMANTHA: ['SAM', 'SAMMY'], ELIZABETH: ['LIZ', 'BETH', 'BETSY', 'LIZZIE', 'ELIZA'],
  KATHERINE: ['KATE', 'KATIE', 'KATHY', 'KAT'], CATHERINE: ['CATHY', 'KATE', 'CAT'], SUSAN: ['SUE', 'SUSIE'],
  MARGARET: ['MAGGIE', 'PEGGY', 'MEG'], ANDREW: ['ANDY', 'DREW'], ALEXANDER: ['ALEX'], ALEXANDRA: ['ALEX', 'SANDRA'],
  EDWARD: ['ED', 'EDDIE', 'TED'], CHARLES: ['CHARLIE', 'CHUCK'], PATRICK: ['PAT'], PATRICIA: ['PAT', 'PATTY', 'TRISH'],
  BENJAMIN: ['BEN', 'BENNY'], JONATHAN: ['JON'], NATHANIEL: ['NATE', 'NATHAN'], DOUGLAS: ['DOUG'], RAYMOND: ['RAY'],
  GERALD: ['GERRY', 'JERRY'], LAWRENCE: ['LARRY'], PHILIP: ['PHIL'], PHILLIP: ['PHIL'], FREDERICK: ['FRED'],
  JENNIFER: ['JEN', 'JENNY'], REBECCA: ['BECKY'], DEBORAH: ['DEB', 'DEBBIE'], VICTORIA: ['VICKY', 'TORI'],
  ZACHARY: ['ZACH'], JOSHUA: ['JOSH'], NICOLE: ['NIKKI'], DONALD: ['DON'], GARY: ['GARRY'],
};

export function normTokens(s: string): string[] {
  return String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toUpperCase()
    .replace(/'/g, '').replace(/[^A-Z]+/g, ' ').trim().split(/\s+/).filter((t) => t && !SUFFIXES.has(t));
}
const joinNorm = (s: string) => normTokens(s).join(' ');

export function jaroWinkler(a: string, b: string): number {
  if (a === b) return 1;
  if (!a || !b) return 0;
  const range = Math.max(0, Math.floor(Math.max(a.length, b.length) / 2) - 1);
  const am = new Array(a.length).fill(false), bm = new Array(b.length).fill(false);
  let m = 0;
  for (let i = 0; i < a.length; i++) {
    for (let j = Math.max(0, i - range); j < Math.min(b.length, i + range + 1); j++) {
      if (!bm[j] && a[i] === b[j]) { am[i] = bm[j] = true; m++; break; }
    }
  }
  if (!m) return 0;
  let t = 0, k = 0;
  for (let i = 0; i < a.length; i++) {
    if (!am[i]) continue;
    while (!bm[k]) k++;
    if (a[i] !== b[k]) t++;
    k++;
  }
  const jaro = (m / a.length + m / b.length + (m - t / 2) / m) / 3;
  let p = 0;
  while (p < 4 && p < a.length && p < b.length && a[p] === b[p]) p++;
  return jaro + p * 0.1 * (1 - jaro);
}

function isNickname(a: string, b: string): boolean {
  return (NICKNAMES[a] || []).includes(b) || (NICKNAMES[b] || []).includes(a);
}
function firstSim(sys: string, man: string): { s: number; nick: boolean } {
  if (!sys || !man) return { s: 0, nick: false };
  if (sys === man) return { s: 1, nick: false };
  if (isNickname(sys, man)) return { s: 0.95, nick: true };
  if (sys.length === 1 && man.startsWith(sys)) return { s: 0.9, nick: false };      // initial: "J SMITH"
  return { s: jaroWinkler(sys, man), nick: false };
}

type Score = { score: number; kind: MatchKind };
// sys: our tokens ("FIRST [MIDDLE] LAST"), compared with the manifest's first/middle/last.
export function scoreName(sysName: string, p: ManifestPassenger): Score | null {
  const sys = normTokens(sysName), last = normTokens(p.last), firsts = normTokens(p.first), mids = normTokens(p.middle);
  if (sys.length < 2 || !last.length || !firsts.length) return null;
  const tryOrder = (sFirst: string, sRest: string[]): Score | null => {
    // Surname: every manifest surname token must find a close token among our remaining tokens
    // ("DALY CARNELL" vs "DALY-CARNELL", "OCONNOR" vs "O CONNOR" joined below).
    const restJoined = sRest.join('');
    let lastS = 0;
    const lastJoined = last.join('');
    lastS = Math.max(jaroWinkler(restJoined, lastJoined), ...sRest.map((t) => Math.max(...last.map((l) => jaroWinkler(t, l)))) );
    if (last.length > 1) lastS = Math.max(lastS, Math.min(...last.map((l) => Math.max(...sRest.map((t) => jaroWinkler(t, l))))));
    const f1 = firstSim(sFirst, firsts[0]);
    const fm = mids.length ? firstSim(sFirst, mids[0]) : { s: 0, nick: false };       // goes by the middle name
    const f = f1.s >= fm.s ? f1 : { s: fm.s - 0.03, nick: fm.nick };
    if (lastS >= 0.999 && f.s >= 0.999) return { score: 1, kind: 'exact' };
    if (lastS >= 0.9 && f.s >= 0.85) return { score: 0.5 * lastS + 0.5 * f.s - 0.01, kind: f.nick ? 'nickname' : 'typo' };
    if (lastS >= 0.999 && f.s >= 0.75) return { score: 0.8 + 0.1 * f.s, kind: 'typo' };
    if (lastS >= 0.999) return { score: 0.6, kind: 'surname_only' };
    return null;
  };
  const a = tryOrder(sys[0], sys.slice(1));
  const b = tryOrder(sys[sys.length - 1], sys.slice(0, -1));   // typed "LAST FIRST"
  if (!a) return b;
  if (!b) return a;
  return b.score > a.score + 0.05 ? b : a;
}

export function parseDate(s: string | null | undefined): string | null {
  const m = String(s || '').trim().match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})/);
  if (m) return `${m[3]}-${m[1].padStart(2, '0')}-${m[2].padStart(2, '0')}`;
  const iso = String(s || '').trim().match(/^(\d{4})-(\d{2})-(\d{2})/);
  return iso ? `${iso[1]}-${iso[2]}-${iso[3]}` : null;
}
export function normRegistration(s: string): string {
  return String(s || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
}
export function normTime(s: string): string {
  const m = String(s || '').match(/(\d{1,2}):(\d{2})/);
  return m ? `${m[1].padStart(2, '0')}:${m[2]}` : '';
}
// The value staff would type in return_flight: the known two-letter suffix, else the registration.
export function flightValueFor(reg: string): string {
  const r = normRegistration(reg);
  if (!r) return '';
  const suf = r.slice(-2);
  return TAIL_SUFFIX_TO_REGISTRATION[suf] === r ? suf : r;
}
export function manifestDisplayName(p: ManifestPassenger): string {
  const first = String(p.first || '').trim().split(/\s+/)[0] || '';
  return `${first} ${String(p.last || '').replace(/\s*-\s*/g, '-').trim()}`.toUpperCase().replace(/\s+/g, ' ').trim();
}

export function matchManifest(pages: ManifestPage[], candidates: Candidate[], feedback: Feedback[]): MatchResult {
  const fb = new Map<string, 'same' | 'different'>();
  for (const f of feedback) fb.set(`${joinNorm(f.manifest_name)}|${joinNorm(f.system_name)}`, f.verdict);

  const dates = pages.map((p) => parseDate(p.manifest_date)).filter(Boolean) as string[];
  const counts = new Map<string, number>();
  for (const d of dates) counts.set(d, (counts.get(d) || 0) + 1);
  const manifestDate = [...counts.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] || null;

  type Row = { page: ManifestPage; p: ManifestPassenger };
  const rows: Row[] = pages.flatMap((page) => page.passengers.map((p) => ({ page, p })));
  const pool = candidates.filter((c) => c.status === 'PENDING' || (c.status === 'DELIVERED' && manifestDate && parseDate(c.deldate) === manifestDate));

  type Pair = { r: number; c: number; s: Score };
  const pairs: Pair[] = [];
  rows.forEach((row, ri) => {
    const mName = manifestDisplayName(row.p);
    pool.forEach((cand, ci) => {
      const verdict = fb.get(`${joinNorm(mName)}|${joinNorm(cand.name)}`);
      if (verdict === 'different') return;
      if (verdict === 'same') { pairs.push({ r: ri, c: ci, s: { score: 0.99, kind: 'taught' } }); return; }
      const s = scoreName(cand.name, row.p);
      if (s) pairs.push({ r: ri, c: ci, s });
    });
  });
  // Best pairs first; a surname-only pair never beats a real first-name match for the same row/car.
  pairs.sort((a, b) => b.s.score - a.s.score);
  const usedR = new Set<number>(), usedC = new Set<number>();
  const matches: Match[] = [];
  for (const pr of pairs) {
    if (usedR.has(pr.r) || usedC.has(pr.c)) continue;
    usedR.add(pr.r); usedC.add(pr.c);
    const { page, p } = rows[pr.r], cand = pool[pr.c];
    const md = parseDate(page.manifest_date) || manifestDate || '';
    const ret = parseDate(cand.ret);
    const state: MatchState = cand.status === 'DELIVERED' ? 'delivered' : !ret ? 'no_date' : ret === md ? 'ok' : ret > md ? 'early' : 'late';
    const mName = manifestDisplayName(p);
    const reg = normRegistration(page.tail_number);
    const fv = flightValueFor(reg), tv = normTime(page.arrival_time);
    const curF = String(cand.return_flight || '').trim().toUpperCase(), curT = String(cand.departure_time || '').trim();
    const curFReg = TAIL_SUFFIX_TO_REGISTRATION[curF.split(/\s+/)[0]] || normRegistration(curF);
    matches.push({
      passenger_id: cand.id, ticket: cand.ticket, system_name: cand.name, manifest_name: mName, kind: pr.s.kind, score: Math.round(pr.s.score * 100) / 100,
      state, ret: cand.ret, manifest_date: md, operator: cand.return_operator || null,
      flight_number: page.flight_number, route: page.route, registration: reg, arrival_time: tv,
      day_trip: String(p.first_origin || '').toUpperCase() === 'FXE', ascend: !!page.ascend_mark,
      suggest_name: joinNorm(mName) !== joinNorm(cand.name) && pr.s.kind !== 'surname_only' ? mName : null,
      suggest_flight: fv && curFReg !== reg ? fv : null,
      suggest_time: tv && normTime(curT) !== tv ? tv : null,
      current_flight: curF, current_time: curT,
    });
  }
  const matchedIds = new Set(matches.map((m) => m.passenger_id));
  const missing: Missing[] = manifestDate ? pool
    .filter((c) => c.status === 'PENDING' && parseDate(c.ret) === manifestDate && !matchedIds.has(c.id))
    .map((c) => ({ passenger_id: c.id, ticket: c.ticket, system_name: c.name, ret: c.ret, operator: c.return_operator || null })) : [];
  const order: Record<MatchState, number> = { early: 0, late: 1, no_date: 2, ok: 3, delivered: 4 };
  matches.sort((a, b) => order[a.state] - order[b.state] || a.arrival_time.localeCompare(b.arrival_time));
  return { manifest_date: manifestDate, matches, missing, manifest_rows: rows.length };
}
